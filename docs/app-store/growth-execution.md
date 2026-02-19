# ClipDock Growth Execution Checklist

Updated: 2026-02-19

This file converts `/Users/wenfeng/Documents/iphoneapp/docs/app-store/growth-playbook.md` into executable steps.

## 0. Day-0 Baseline (must do first)

Data source: App Store Connect -> App Analytics

- [ ] Record date range (last 7 days)
- [ ] Record `Impressions` (曝光)
- [ ] Record `Product Page Views` (产品页浏览)
- [ ] Record `Conversion Rate` (转化率)
- [ ] Record `First-Time Downloads` (首次下载)
- [ ] Record top `Acquisition Sources` (来源渠道)

Write baseline to:
- `/Users/wenfeng/Documents/iphoneapp/docs/app-store/metrics-template.csv`

## 1. ASO Iteration (every 2 weeks)

Where to edit:
1. App Store Connect -> My Apps -> ClipDock: Free Up Space
2. App Store -> iOS App -> current editable version
3. Switch localization: `English (U.S.)` and `简体中文`

Fields to update:
- [ ] Subtitle
- [ ] Keywords (comma-separated, <=100 chars)
- [ ] Description opening lines (first 2-3 lines)
- [ ] Screenshots (top 1-3 priority)

Done definition:
- [ ] Saved without validation errors in both `en-US` and `zh-Hans`
- [ ] Submission completed (if metadata review required)
- [ ] Next check date set (T+14 days)

## 2. Screenshot Pack (CN + US)

Required outputs:
- [ ] 5 screenshot frames in `en-US`
- [ ] 5 screenshot frames in `zh-Hans`
- [ ] First 3 screenshots focus on value/results

Local assets:
- 6.5 inch base screenshot: `/Users/wenfeng/Documents/iphoneapp/docs/app-store/screenshots/iphone65-1.png`
- Script: `/Users/wenfeng/Documents/iphoneapp/scripts/generate_app_store_screenshot_iphone65.sh`

Done definition:
- [ ] Uploaded to both localizations
- [ ] App Store page preview confirmed on phone

## 3. Custom Product Pages (next week)

Create 3 CPP pages:
- [ ] A: Free Up Space
- [ ] B: External Drive Export
- [ ] C: Large Video Cleanup

Per page:
- [ ] Unique screenshots + subtitle text
- [ ] One dedicated external channel link

Done definition:
- [ ] 3 CPP links created
- [ ] Channel mapping documented (one channel -> one CPP)

## 4. Content Distribution (weekly loop)

China:
- [ ] Xiaohongshu post
- [ ] Bilibili short demo
- [ ] Douyin short demo

US:
- [ ] Reddit post (`r/iosapps`, `r/iPhone` etc.)
- [ ] Product Hunt launch/update

Rules:
- [ ] One canonical landing link per channel
- [ ] Every post includes real workflow: before -> migrate -> free space

Done definition:
- [ ] At least 1 CN + 1 US channel published each week
- [ ] Weekly source contribution reviewed in analytics

## 5. Optional Apple Ads (7-day test)

Setup:
- [ ] Campaign 1: Brand terms
- [ ] Campaign 2: High-intent generic terms
- [ ] Low daily budget for 7 days

Decision rule:
- [ ] Keep terms with low CPI and acceptable conversion
- [ ] Pause high-spend low-download terms

Done definition:
- [ ] 7-day report exported
- [ ] Keep/pause list updated

## 6. In-App Growth Loop (product backlog)

Implement in next app updates:
- [ ] Post-success "space freed" feedback
- [ ] Rating prompt after >=2 successful migrations
- [ ] Feedback path for unhappy users (avoid direct bad review funnel)
- [ ] Optional reminder for next cleanup
- [ ] Optional share card for migration result

Done definition:
- [ ] PRD items created as GitHub issues
- [ ] Prioritized into next release (`1.0.2+`)

