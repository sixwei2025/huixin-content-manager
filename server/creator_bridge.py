#!/usr/bin/env python3
"""汇芯内容管家 · 本机创作者中心直连桥接器（只读采集 + 人工扫码登录）。

支持平台：
- douyin   (抖音创作者中心，优先复用 ~/lab/douyin-publisher/profile)
- channels (微信视频号助手，优先探测本机 9333/9335/9334 CDP，否则使用独立 profile)
- xhs      (小红书创作者平台，~/.huixin-content-manager/profiles/xhs)

严禁任何绕过登录或验证码的行为；未登录时明确返回 need_login，并由用户通过 `login` 子命令亲手扫码。
"""

import argparse
import asyncio
import json
import os
import re
import sys
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from playwright.async_api import async_playwright

HOME = Path.home()
STATE_DIR = HOME / ".huixin-content-manager"
PROFILES_DIR = STATE_DIR / "profiles"
CACHE_PATH = STATE_DIR / "cache" / "platform_metrics.json"
DOUYIN_EXISTING_PROFILE = HOME / "lab" / "douyin-publisher" / "profile"

CHANNEL_CDP_PORTS = [
    ("袁六伟", 9333),
    ("汇芯袁总", 9335),
    ("山河来电", 9334),
]

PLATFORM_URLS = {
    "douyin": {
        "login": "https://creator.douyin.com/",
        "home": "https://creator.douyin.com/creator-micro/home",
        "op": "https://creator.douyin.com/creator-micro/data-center/operation",
        "manage": "https://creator.douyin.com/creator-micro/content/manage",
    },
    "channels": {
        "login": "https://channels.weixin.qq.com/platform",
        "home": "https://channels.weixin.qq.com/platform",
        "list": "https://channels.weixin.qq.com/platform/post/list",
    },
    "channels_huixin": {
        "login": "https://channels.weixin.qq.com/platform",
        "home": "https://channels.weixin.qq.com/platform",
        "list": "https://channels.weixin.qq.com/platform/post/list",
    },
    "channels_shanhe": {
        "login": "https://channels.weixin.qq.com/platform",
        "home": "https://channels.weixin.qq.com/platform",
        "list": "https://channels.weixin.qq.com/platform/post/list",
    },
    "xhs": {
        "login": "https://creator.xiaohongshu.com/login",
        "home": "https://creator.xiaohongshu.com/new/home",
        "notes": "https://creator.xiaohongshu.com/new/note-manager",
    },
    "wechat": {
        "login": "https://mp.weixin.qq.com/",
        "home": "https://mp.weixin.qq.com/",
    },
}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def ensure_dirs() -> None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)


def profile_dir_for(platform: str) -> Path:
    if platform == "douyin" and DOUYIN_EXISTING_PROFILE.exists():
        return DOUYIN_EXISTING_PROFILE
    p = PROFILES_DIR / platform
    p.mkdir(parents=True, exist_ok=True)
    return p


def load_cache() -> Dict[str, Any]:
    if CACHE_PATH.exists():
        try:
            return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_cache(data: Dict[str, Any]) -> None:
    ensure_dirs()
    CACHE_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def parse_cn_number(raw: str) -> Optional[int]:
    if not raw:
        return None
    s = raw.strip().replace(",", "").replace(" ", "")
    m = re.search(r"([+-]?\d+(?:\.\d+)?)\s*(亿|万|w|W|k|K)?", s)
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2) or ""
    if unit == "亿":
        val *= 100_000_000
    elif unit in ("万", "w", "W"):
        val *= 10_000
    elif unit in ("k", "K"):
        val *= 1_000
    return int(round(val))


def num_before(text: str, labels: List[str], window: int = 40) -> Optional[int]:
    for label in labels:
        idx = text.find(label)
        if idx <= 0:
            continue
        chunk = text[max(0, idx - window) : idx]
        matches = re.findall(r"([+-]?\d[\d,]*(?:\.\d+)?\s*(?:亿|万|w|W|k|K)?)", chunk)
        if matches:
            parsed = parse_cn_number(matches[-1])
            if parsed is not None:
                return parsed
    return None


def num_after(text: str, labels: List[str], window: int = 80) -> Optional[int]:
    for label in labels:
        idx = text.find(label)
        if idx < 0:
            continue
        chunk = text[idx + len(label) : idx + len(label) + window]
        # Skip punctuation/newlines between label and number
        m = re.search(r"([+-]?\d[\d,]*(?:\.\d+)?\s*(?:亿|万|w|W|k|K)?)", chunk)
        if m:
            parsed = parse_cn_number(m.group(1))
            if parsed is not None:
                return parsed
    return None


def cdp_is_alive(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=1.2) as resp:
            return resp.status == 200
    except Exception:
        return False


def cdp_tabs(port: int) -> List[Dict[str, Any]]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=1.5) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return []


async def launch_profile_context(playwright, platform: str, headless: bool):
    pdir = profile_dir_for(platform)
    args = ["--mute-audio", "--disable-blink-features=AutomationControlled"]
    try:
        return await playwright.chromium.launch_persistent_context(
            str(pdir),
            headless=headless,
            channel="chrome",
            args=args,
            viewport={"width": 1360, "height": 860},
        )
    except Exception:
        return await playwright.chromium.launch_persistent_context(
            str(pdir),
            headless=headless,
            args=args,
            viewport={"width": 1360, "height": 860},
        )


async def sync_douyin(playwright) -> Dict[str, Any]:
    res: Dict[str, Any] = {
        "platform": "抖音",
        "key": "douyin",
        "ok": False,
        "need_login": False,
        "source": "抖音创作者中心",
        "updated_at": now_iso(),
        "items": [],
    }
    ctx = None
    try:
        ctx = await launch_profile_context(playwright, "douyin", headless=True)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(PLATFORM_URLS["douyin"]["home"], wait_until="domcontentloaded", timeout=35000)
        await page.wait_for_timeout(4000)

        url = page.url or ""
        body = await page.locator("body").first.inner_text()
        if "login" in url.lower() or "扫码登录" in body or "验证码登录" in body:
            res["need_login"] = True
            res["message"] = "需要抖音扫码登录"
            return res

        # Extract account name and home summary
        skip_nav = {"作品发布", "首页", "内容管理", "数据中心", "收入变现", "高清发布", "创作服务", "灵感中心", "活动中心", "创作者学习中心"}
        lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
        account_name = next((ln for ln in lines[:20] if 2 <= len(ln) <= 20 and ln not in skip_nav and not re.fullmatch(r"[\d,.万wWkK+%:：-]+", ln)), "")

        fans = num_after(body, ["总粉丝量", "粉丝数", "粉丝总量", "粉丝"])
        likes = num_after(body, ["获赞", "总点赞量", "点赞"])

        # Go to operation data center for yesterday/7d metrics
        await page.goto(PLATFORM_URLS["douyin"]["op"], wait_until="domcontentloaded", timeout=35000)
        await page.wait_for_timeout(4500)
        op_body = await page.locator("body").inner_text()
        if "login" in (page.url or "").lower() or "扫码登录" in op_body:
            res["need_login"] = True
            res["message"] = "需要抖音扫码登录"
            return res

        fans = num_after(op_body, ["总粉丝量", "粉丝总量"]) or fans
        delta = num_after(op_body, ["粉丝净增", "净增粉丝", "新增粉丝"])
        views = num_after(op_body, ["总播放量", "播放量", "作品播放"])
        likes = num_after(op_body, ["总点赞量", "点赞量"]) or likes
        comments = num_after(op_body, ["总评论量", "评论量"])
        shares = num_after(op_body, ["总分享量", "分享量"])

        # Fetch recent works from content manage
        items: List[Dict[str, Any]] = []
        posts_count: Optional[int] = None
        try:
            await page.goto(PLATFORM_URLS["douyin"]["manage"], wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_timeout(3500)
            manage_body = await page.locator("body").inner_text()
            m_total = re.search(r"共\s*(\d+)\s*个作品|全部作品\s*\(?(\d+)\)?", manage_body)
            if m_total:
                posts_count = int(m_total.group(1) or m_total.group(2))
            # Extract video titles + play counts heuristically from manage cards
            raw_items = await page.evaluate(
                """() => {
                    const out = [];
                    const cards = document.querySelectorAll('[class*="video-card"], [class*="content-item"], [class*="article-card"]');
                    for (const c of cards) {
                        const t = (c.innerText || '').trim();
                        if (!t || t.length < 4) continue;
                        const lines = t.split('\\n').map(x => x.trim()).filter(x => x && !/^\\d{1,2}:\\d{2}$/.test(x) && !/^置顶$/.test(x));
                        const title = lines.find(x => x.length >= 4 && !/^(已发布|审核中|未通过|播放|点赞|评论|分享|\\d+)$/.test(x));
                        if (title) {
                            out.push({ title: title.slice(0, 60), raw: lines.join(' · ') });
                        }
                        if (out.length >= 6) break;
                    }
                    return out;
                }"""
            )
            for it in raw_items or []:
                title = it.get("title", "").strip()
                raw = it.get("raw", "")
                if title and title not in {"作品管理", "全部作品"}:
                    m_views = re.search(r"播放\s*([\d.,]+[万wWkK]?)", raw)
                    m_likes = re.search(r"点赞\s*([\d.,]+[万wWkK]?)", raw)
                    items.append({
                        "title": title,
                        "platform": "抖音",
                        "status": "已发布",
                        "views": m_views.group(1) if m_views else "—",
                        "likes": m_likes.group(1) if m_likes else "—",
                    })
        except Exception:
            pass

        res.update({
            "ok": True,
            "account": account_name or "抖音创作者",
            "followers": fans,
            "delta": delta,
            "posts": posts_count if posts_count is not None else len(items),
            "views": views,
            "likes": likes,
            "comments": comments,
            "shares": shares,
            "items": items[:5],
            "message": f"已连接 · {account_name or '抖音创作者'}",
        })
        return res
    except Exception as e:
        res["message"] = f"抖音同步失败：{e}"
        return res
    finally:
        if ctx is not None:
            await ctx.close()


async def sync_bilibili(playwright) -> Dict[str, Any]:
    res: Dict[str, Any] = {
        "platform": "B站",
        "key": "bilibili",
        "ok": False,
        "need_login": False,
        "source": "B站创作中心",
        "updated_at": now_iso(),
        "items": [],
    }
    ctx = None
    try:
        ctx = await launch_profile_context(playwright, "bilibili", headless=True)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(PLATFORM_URLS["bilibili"]["home"], wait_until="domcontentloaded", timeout=35000)
        await page.wait_for_timeout(3000)

        url = page.url or ""
        if "passport.bilibili.com" in url or "login" in url.lower():
            res["need_login"] = True
            res["message"] = "需要 B 站扫码登录"
            return res

        # Query Bilibili creator center web APIs inside authenticated page context
        stat_json = await page.evaluate(
            """async () => {
                try {
                    const r = await fetch('https://member.bilibili.com/x/web/index/stat', { credentials: 'include' });
                    return await r.json();
                } catch (e) {
                    return { code: -1, message: String(e) };
                }
            }"""
        )
        if not isinstance(stat_json, dict) or stat_json.get("code") != 0:
            code = stat_json.get("code") if isinstance(stat_json, dict) else -1
            if code in (-101, -111):
                res["need_login"] = True
                res["message"] = "需要 B 站扫码登录"
                return res
            res["message"] = (stat_json or {}).get("message") or "B站创作中心接口未返回数据"
            return res

        data = stat_json.get("data") or {}
        fans = data.get("total_fans")
        incr_fans = data.get("incr_fans")
        plays = data.get("total_click") or data.get("incr_click")
        likes = data.get("total_like") or data.get("incr_like")
        comments = data.get("total_reply") or data.get("incr_reply")
        favs = data.get("total_fav") or data.get("incr_fav")

        # Also fetch recent published videos + user nav info
        nav_json = await page.evaluate(
            """async () => {
                try {
                    const r = await fetch('https://api.bilibili.com/x/web-interface/nav', { credentials: 'include' });
                    return await r.json();
                } catch (e) { return {}; }
            }"""
        )
        uname = ((nav_json or {}).get("data") or {}).get("uname") or "B站UP主"

        list_json = await page.evaluate(
            """async () => {
                try {
                    const r = await fetch('https://member.bilibili.com/x/vu/web/list?status=pubed&pn=1&ps=10', { credentials: 'include' });
                    return await r.json();
                } catch (e) { return {}; }
            }"""
        )
        list_data = (list_json or {}).get("data") or {}
        arc_audits = list_data.get("arc_audits") or []
        total_posts = ((list_data.get("page") or {}).get("count")) or len(arc_audits)

        items: List[Dict[str, Any]] = []
        for entry in arc_audits[:5]:
            arc = entry.get("Archive") or {}
            stat = entry.get("stat") or {}
            items.append({
                "title": arc.get("title") or "未命名稿件",
                "platform": "B站",
                "status": "已发布",
                "views": str(stat.get("view", "—")),
                "likes": str(stat.get("like", "—")),
            })

        res.update({
            "ok": True,
            "account": uname,
            "followers": fans,
            "delta": incr_fans,
            "posts": total_posts,
            "views": plays,
            "likes": likes,
            "comments": comments,
            "saves": favs,
            "items": items,
            "message": f"已连接 · {uname}",
        })
        return res
    except Exception as e:
        res["message"] = f"B站同步失败：{e}"
        return res
    finally:
        if ctx is not None:
            await ctx.close()


async def sync_channels_account(
    playwright,
    key: str,
    display_platform: str,
    default_name: str,
    preferred_port: Optional[int] = None,
) -> Dict[str, Any]:
    res: Dict[str, Any] = {
        "platform": display_platform,
        "key": key,
        "ok": False,
        "need_login": False,
        "source": "微信视频号助手",
        "updated_at": now_iso(),
        "items": [],
    }
    # Prefer live CDP daemon for this specific account ONLY if already logged in
    live_port = None
    if preferred_port is not None and cdp_is_alive(preferred_port):
        tabs = cdp_tabs(preferred_port)
        if any("channels.weixin.qq.com" in (t.get("url") or "") and "login" not in (t.get("url") or "") for t in tabs):
            live_port = preferred_port

    browser = None
    ctx = None
    try:
        if live_port is not None:
            browser = await playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{live_port}")
            ctx = browser.contexts[0]
            page = next((p for p in ctx.pages if "channels.weixin.qq.com" in (p.url or "")), None) or await ctx.new_page()
            if "channels.weixin.qq.com" not in (page.url or ""):
                await page.goto(PLATFORM_URLS["channels"]["home"], wait_until="domcontentloaded", timeout=30000)
                await page.wait_for_timeout(3000)
            if "login" in (page.url or "").lower():
                await page.reload(wait_until="domcontentloaded", timeout=20000)
                await page.wait_for_timeout(2000)
        else:
            ctx = await launch_profile_context(playwright, key, headless=True)
            page = ctx.pages[0] if ctx.pages else await ctx.new_page()
            await page.goto(PLATFORM_URLS["channels"]["home"], wait_until="domcontentloaded", timeout=35000)
            await page.wait_for_timeout(3500)

        url = page.url or ""
        body = await page.locator("body").first.inner_text()
        if "login" in url.lower() or "微信扫码" in body or "登录视频号助手" in body:
            res["need_login"] = True
            res["message"] = f"需要微信扫码登录（{default_name}）"
            return res

        # Extract account name and metrics from 视频号助手首页
        lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
        account_name = next((ln for ln in lines[:15] if 2 <= len(ln) <= 20 and "视频号" not in ln and not re.fullmatch(r"[\d,.]+", ln) and ln not in {"首页", "内容管理", "数据中心", "直播", "私信", "评论"}), "")
        fans = num_after(body, ["关注者", "关注人数", "粉丝数", "总关注人数"])
        delta = num_after(body, ["净增关注", "净增粉丝"])
        views = num_after(body, ["新增播放", "播放量", "浏览量", "总播放"])
        likes = num_after(body, ["新增\n", "新增点赞", "点赞", "喜欢"])
        comments = num_after(body, ["新增评论", "评论"])
        shares = num_after(body, ["新增分享", "分享", "转发"])
        posts = num_after(body, ["视频", "发表内容", "视频数", "作品数"])

        items: List[Dict[str, Any]] = []
        try:
            await page.goto(PLATFORM_URLS["channels"]["list"], wait_until="domcontentloaded", timeout=25000)
            await page.wait_for_timeout(3000)
            raw_items = await page.evaluate(
                """() => {
                    const out = [];
                    const cards = document.querySelectorAll('.post-list-item, [class*="feed-item"], [class*="post-item"], [class*="video-item"]');
                    for (const c of cards) {
                        const t = (c.innerText || '').trim();
                        if (!t || t.length < 4) continue;
                        const ls = t.split('\\n').map(x => x.trim()).filter(Boolean);
                        if (ls.length >= 1) out.push({ title: ls[0].slice(0, 60) });
                        if (out.length >= 5) break;
                    }
                    return out;
                }"""
            )
            for it in raw_items or []:
                items.append({"title": it.get("title", "视频号动态"), "platform": display_platform, "status": "已发布", "views": "—", "likes": "—"})
        except Exception:
            pass

        res.update({
            "ok": True,
            "account": account_name or default_name,
            "followers": fans,
            "delta": delta,
            "posts": posts if posts is not None else (len(items) if items else None),
            "views": views,
            "likes": likes,
            "comments": comments,
            "shares": shares,
            "items": items,
            "message": f"已连接 · {account_name or default_name}",
        })
        return res
    except Exception as e:
        res["message"] = f"{display_platform}同步失败：{e}"
        return res
    finally:
        if browser is not None:
            await browser.close()
        elif ctx is not None:
            await ctx.close()


async def sync_channels(playwright) -> Dict[str, Any]:
    return await sync_channels_account(playwright, "channels", "视频号 · 袁六伟", "袁六伟", 9333)


async def sync_channels_huixin(playwright) -> Dict[str, Any]:
    return await sync_channels_account(playwright, "channels_huixin", "视频号 · 汇芯袁总", "汇芯袁总", 9335)


async def sync_channels_shanhe(playwright) -> Dict[str, Any]:
    return await sync_channels_account(playwright, "channels_shanhe", "视频号 · 山河来电", "山河来电", 9334)


async def sync_xhs(playwright) -> Dict[str, Any]:
    res: Dict[str, Any] = {
        "platform": "小红书",
        "key": "xhs",
        "ok": False,
        "need_login": False,
        "source": "小红书创作者平台",
        "updated_at": now_iso(),
        "items": [],
    }
    ctx = None
    try:
        ctx = await launch_profile_context(playwright, "xhs", headless=True)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(PLATFORM_URLS["xhs"]["home"], wait_until="domcontentloaded", timeout=35000)
        await page.wait_for_timeout(3500)

        url = page.url or ""
        body = await page.locator("body").first.inner_text()
        if "login" in url.lower() or "短信登录" in body or "扫码登录" in body:
            res["need_login"] = True
            res["message"] = "需要小红书扫码登录"
            return res

        lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
        account_name = next((ln for ln in lines[:10] if 2 <= len(ln) <= 20 and ln not in {"创作服务平台", "发布笔记", "首页", "笔记管理", "Builder hub", "小工具", "Red Skill", "数据看板", "活动中心"}), "小红书创作者")
        fans = num_before(body, ["粉丝数"]) or num_after(body, ["粉丝数", "粉丝"])
        likes = num_before(body, ["获赞与收藏"]) or num_after(body, ["获赞与收藏", "获赞"])
        overview_idx = body.find("笔记数据总览")
        ov_text = body[overview_idx:] if overview_idx >= 0 else body
        views = num_after(ov_text, ["曝光量", "观看量", "阅读量", "总曝光"])
        posts = num_after(ov_text, ["发布笔记", "笔记数", "已发布"])

        res.update({
            "ok": True,
            "account": account_name,
            "followers": fans,
            "posts": posts,
            "views": views,
            "likes": likes,
            "message": f"已连接 · {account_name}",
        })
        return res
    except Exception as e:
        res["message"] = f"小红书同步失败：{e}"
        return res
    finally:
        if ctx is not None:
            await ctx.close()


async def sync_wechat(playwright) -> Dict[str, Any]:
    res: Dict[str, Any] = {
        "platform": "公众号",
        "key": "wechat",
        "ok": False,
        "need_login": False,
        "source": "微信公众平台",
        "updated_at": now_iso(),
        "items": [],
    }
    ctx = None
    try:
        ctx = await launch_profile_context(playwright, "wechat", headless=True)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(PLATFORM_URLS["wechat"]["home"], wait_until="domcontentloaded", timeout=35000)
        await page.wait_for_timeout(3500)

        url = page.url or ""
        body = await page.locator("body").first.inner_text()
        if "token=" not in url and ("微信扫一扫" in body or "登录" in body[:200] or "使用账号登录" in body):
            res["need_login"] = True
            res["message"] = "需要微信扫码登录（公众号）"
            return res

        fans = num_after(body, ["总用户数", "粉丝数", "关注人数"])
        delta = num_after(body, ["昨日净增", "净增关注", "新增人数"])
        views = num_after(body, ["阅读次数", "昨日阅读", "阅读"])
        posts = num_after(body, ["已群发", "群发", "文章数"])
        lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
        account_name = next((ln for ln in lines[:15] if 2 <= len(ln) <= 20 and ln not in {"首页", "微信公众平台", "公众平台", "消息", "留言", "赞赏", "内容管理", "数据统计"} and "公众平台" not in ln and not re.fullmatch(r"[\d,.]+", ln)), "公众号")

        res.update({
            "ok": True,
            "account": account_name,
            "followers": fans,
            "delta": delta,
            "posts": posts,
            "views": views,
            "message": f"已连接 · {account_name}",
        })
        return res
    except Exception as e:
        res["message"] = f"公众号同步失败：{e}"
        return res
    finally:
        if ctx is not None:
            await ctx.close()


SYNC_HANDLERS = {
    "douyin": sync_douyin,
    "channels": sync_channels,
    "channels_huixin": sync_channels_huixin,
    "channels_shanhe": sync_channels_shanhe,
    "xhs": sync_xhs,
    "wechat": sync_wechat,
}


async def run_login(platform: str, timeout_sec: int = 180) -> Dict[str, Any]:
    if platform not in PLATFORM_URLS:
        return {"ok": False, "message": f"不支持的平台：{platform}"}

    async with async_playwright() as p:
        ctx = await launch_profile_context(p, platform, headless=False)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(PLATFORM_URLS[platform]["login"], wait_until="domcontentloaded", timeout=45000)

        # Wait until URL leaves login page (or timeout)
        logged_in = False
        for _ in range(timeout_sec):
            await asyncio.sleep(1)
            if not ctx.pages:
                break
            cur = page.url or ""
            if platform == "douyin" and "creator-micro/home" in cur:
                logged_in = True
                break
            if platform.startswith("channels") and "channels.weixin.qq.com/platform" in cur and "login" not in cur:
                logged_in = True
                break
            if platform == "xhs" and "creator.xiaohongshu.com/new/" in cur:
                logged_in = True
                break
            if platform == "wechat" and "mp.weixin.qq.com/cgi-bin/" in cur and "token=" in cur:
                logged_in = True
                break
        await page.wait_for_timeout(2000)
        await ctx.close()

    if logged_in:
        return await run_sync(platform)
    return {"platform": platform, "ok": False, "need_login": True, "message": "未检测到登录完成，请重试"}


async def run_sync(platform: str) -> Dict[str, Any]:
    targets = list(SYNC_HANDLERS.keys()) if platform == "all" else [platform]
    cache = load_cache()
    results: Dict[str, Any] = {}
    async with async_playwright() as p:
        for key in targets:
            handler = SYNC_HANDLERS.get(key)
            if not handler:
                continue
            r = await handler(p)
            results[key] = r
            if r.get("ok"):
                cache[key] = r
    save_cache(cache)
    return results if platform == "all" else results.get(platform, {"ok": False, "message": "未知平台"})


async def run_keepalive() -> Dict[str, Any]:
    """Silently refresh cookies/sessions for already logged-in profiles to extend login lifetime."""
    cache = load_cache()
    refreshed: Dict[str, Any] = {}
    async with async_playwright() as p:
        for key, handler in SYNC_HANDLERS.items():
            # Only touch profiles that have previously succeeded or exist on disk
            if key not in cache and not (PROFILES_DIR / key).exists() and key != "douyin":
                continue
            r = await handler(p)
            refreshed[key] = {"ok": r.get("ok", False), "need_login": r.get("need_login", False)}
            if r.get("ok"):
                cache[key] = r
    save_cache(cache)
    return refreshed


def cmd_status() -> Dict[str, Any]:
    cache = load_cache()
    out: Dict[str, Any] = {"cache": cache, "cdp": {}}
    for name, port in CHANNEL_CDP_PORTS:
        alive = cdp_is_alive(port)
        tabs = cdp_tabs(port) if alive else []
        logged = any("channels.weixin.qq.com" in (t.get("url") or "") and "login" not in (t.get("url") or "") for t in tabs)
        out["cdp"][name] = {"port": port, "alive": alive, "logged_in": logged}
    out["douyin_profile_exists"] = profile_dir_for("douyin").exists()
    out["xhs_profile_exists"] = profile_dir_for("xhs").exists()
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="汇芯内容管家 · 本机创作者中心直连桥接器")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("keepalive")
    p_sync = sub.add_parser("sync")
    p_sync.add_argument("--platform", default="all", choices=["all", "douyin", "channels", "channels_huixin", "channels_shanhe", "xhs", "wechat"])
    p_login = sub.add_parser("login")
    p_login.add_argument("--platform", required=True, choices=["douyin", "channels", "channels_huixin", "channels_shanhe", "xhs", "wechat"])
    p_login.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    if args.cmd == "status":
        print(json.dumps(cmd_status(), ensure_ascii=False))
    elif args.cmd == "keepalive":
        res = asyncio.run(run_keepalive())
        print(json.dumps(res, ensure_ascii=False))
    elif args.cmd == "sync":
        res = asyncio.run(run_sync(args.platform))
        print(json.dumps(res, ensure_ascii=False))
    elif args.cmd == "login":
        res = asyncio.run(run_login(args.platform, timeout_sec=args.timeout))
        print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
