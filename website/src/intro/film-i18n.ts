// Film copy is written in English in film.html; these tables swap each text node, chapter
// name and label for the page language. Terms follow the site copy in i18n/strings.ts.
import type { Lang } from "../i18n/strings";

type Row = [ja: string, ko: string, zhHant: string];

const T: Record<string, Row> = {
  // Boot and outro
  "All your sources. One big screen.": ["すべてのソースを、ひとつの大画面で。", "모든 소스를, 하나의 큰 화면에서.", "所有片源，盡在大螢幕。"],
  "A native TVBox player for Apple TV": ["Apple TV のためのネイティブ TVBox プレーヤー", "Apple TV를 위한 네이티브 TVBox 플레이어", "為 Apple TV 打造的原生 TVBox 播放器"],
  "iPhone & iPad · iOS 18": ["iPhone・iPad · iOS 18", "iPhone 및 iPad · iOS 18", "iPhone 和 iPad · iOS 18"],
  "Yingxia doesn’t host or provide any content. It plays the subscriptions you add.": ["映匣はコンテンツをホスト・提供しません。追加した配信設定を再生するだけです。", "Yingxia는 어떤 콘텐츠도 호스팅하거나 제공하지 않습니다. 추가한 구독을 재생할 뿐입니다.", "映匣不託管也不提供任何內容，只播放你加入的訂閱。"],

  // Settings
  "Settings": ["設定", "설정", "設定"],
  "Subscriptions": ["配信設定", "구독", "訂閱"],
  "Sources": ["ソース", "소스", "片源"],
  "Runtime": ["ランタイム", "런타임", "執行環境"],
  "Language": ["言語", "언어", "語言"],
  "About": ["情報", "정보", "關於"],
  "Add Subscription": ["配信設定を追加", "구독 추가", "新增訂閱"],
  "Add": ["追加", "추가", "新增"],
  "Loading subscription…": ["配信設定を読み込み中…", "구독 불러오는 중…", "正在載入訂閱…"],
  "sites": ["サイト", "사이트", "站點"],
  "live channels": ["ライブチャンネル", "실시간 채널", "直播頻道"],
  "parsers": ["パーサー", "파서", "解析器"],
  "JAR spider": ["JAR スパイダー", "JAR 스파이더", "JAR 爬蟲"],
  "Add a TVBox subscription once, by URL.": ["TVBox の配信設定は URL で一度追加するだけ。", "TVBox 구독은 URL로 한 번만 추가하세요.", "TVBox 訂閱只要用網址加入一次。"],
  "Yingxia runs every site in it on the device: JSON, JavaScript and JAR.": ["映匣はその中のすべてのサイトをデバイス上で動かします。JSON も JavaScript も JAR も。", "Yingxia는 그 안의 모든 사이트를 기기에서 실행합니다. JSON, JavaScript, JAR 모두.", "映匣在裝置上執行其中每個站點：JSON、JavaScript、JAR 都行。"],

  // Sources grid and a source's shelf
  "Find a source": ["ソースを検索", "소스 찾기", "尋找片源"],
  "Built-in": ["内蔵", "내장", "內建"],
  "Bilibili": ["ビリビリ", "빌리빌리", "嗶哩嗶哩"],
  "Hongguo": ["Hongguo", "Hongguo", "紅果短劇"],
  "Sources sit in a grid like apps. Bilibili and Hongguo come built in.": ["ソースはアプリのように並びます。ビリビリと Hongguo は内蔵。", "소스가 앱처럼 격자로 놓입니다. 빌리빌리와 Hongguo는 내장되어 있습니다.", "片源像 App 一樣排成格狀，並內建嗶哩嗶哩與紅果短劇。"],
  "Search videos": ["動画を検索", "동영상 검색", "搜尋影片"],
  "Recommendations": ["おすすめ", "추천", "推薦"],
  "Page 1 of 50": ["1 / 50 ページ", "1 / 50 페이지", "第 1 頁，共 50 頁"],
  "Every source gets its own shelf: categories, pages and filters.": ["ソースごとに専用の棚。カテゴリー、ページ、フィルターも。", "소스마다 자신만의 진열대: 카테고리, 페이지, 필터.", "每個片源都有自己的片架：分類、分頁與篩選。"],

  // Search
  "Global Search": ["横断検索", "통합 검색", "全域搜尋"],
  "results": ["件", "건", "筆結果"],
  "Sources answered": ["応答したソース", "응답한 소스", "已回應片源"],
  "Stop": ["停止", "정지", "停止"],
  "All Sources": ["すべてのソース", "모든 소스", "全部片源"],
  "One search runs across every source in your subscription.": ["ひとつの検索で、配信設定内のすべてのソースを探します。", "한 번의 검색으로 구독의 모든 소스를 찾습니다.", "一次搜尋，就能找遍訂閱中的所有片源。"],
  "Results appear as each source answers.": ["結果はソースが応答した順に表示されます。", "결과는 소스가 응답하는 대로 표시됩니다.", "結果隨各片源回應陸續出現。"],

  // Player
  "Bilibili ·": ["ビリビリ ·", "빌리빌리 ·", "嗶哩嗶哩 ·"],
  "Quality": ["画質", "화질", "畫質"],
  "Auto": ["自動", "자동", "自動"],
  "Danmaku fly over the video, in step with playback.": ["弾幕が映像の上を流れ、再生とぴったり同期します。", "탄막이 재생에 맞춰 영상 위로 흐릅니다.", "彈幕在畫面上飛過，與播放精準同步。"],
  "Choose the quality, up to 4K, right from the player.": ["画質は最大 4K まで、プレーヤーからすぐに選べます。", "최대 4K까지, 플레이어에서 바로 화질을 고르세요.", "直接在播放器裡選擇畫質，最高 4K。"],

  // Hongguo
  "Episode 4 · 1080×1920": ["第 4 話 · 1080×1920", "4화 · 1080×1920", "第 4 集 · 1080×1920"],
  "Episodes": ["エピソード", "에피소드", "選集"],
  "69 episodes": ["全 69 話", "총 69화", "共 69 集"],
  "New": ["新機能", "새로운 기능", "新功能"],
  "Hongguo short dramas come built in. Every episode streams as you watch.": ["Hongguo のショートドラマも内蔵。どのエピソードも、観ながらストリーミング。", "Hongguo 숏드라마도 내장. 모든 에피소드를 보는 동안 스트리밍합니다.", "也內建紅果短劇，每一集都邊看邊串流。"],

  // Live TV
  "Live TV": ["ライブ TV", "실시간 TV", "直播電視"],
  "Search channels": ["チャンネルを検索", "채널 검색", "搜尋頻道"],
  "All": ["すべて", "전체", "全部"],
  "Channels: 188": ["チャンネル：188", "채널: 188", "頻道：188"],
  "Live TV from M3U or TXT playlists, laid out like a TV guide.": ["M3U・TXT プレイリストのライブ TV を、番組ガイドのように。", "M3U·TXT 재생 목록의 실시간 TV를 편성표처럼.", "M3U、TXT 播放清單的直播電視，像節目表一樣排好。"],

  // Cast
  "Cast": ["キャスト", "캐스트", "投放"],
  "Living Room Speaker": ["リビングのスピーカー", "거실 스피커", "客廳音箱"],
  "Danmaku": ["弾幕", "탄막", "彈幕"],
  "Pause · Seek · Stop": ["一時停止 · シーク · 停止", "일시정지 · 탐색 · 정지", "暫停 · 拖動 · 停止"],
  "Cast from the Bilibili app on your phone. Apple TV plays the HD stream.": ["スマートフォンのビリビリアプリからキャスト。Apple TV が HD で再生します。", "휴대폰의 빌리빌리 앱에서 캐스트하면 Apple TV가 HD로 재생합니다.", "從手機的嗶哩嗶哩 App 投放，Apple TV 播放高畫質串流。"],

  // Every screen
  "Every screen": ["すべての画面で", "모든 화면", "所有螢幕"],
  "No account": ["アカウント不要", "계정 없음", "免帳號"],
  "No analytics": ["解析なし", "분석 없음", "無分析追蹤"],
  "Stays on device": ["データはデバイス内", "기기에만 저장", "資料留在裝置上"],
  "Logs redact secrets": ["ログの秘密情報は伏せ字", "로그의 비밀 정보 가림", "日誌遮蔽機密"],
  "One app for Apple TV, iPhone, iPad and Mac. No account, no analytics.": ["Apple TV、iPhone、iPad、Mac にひとつのアプリ。アカウントも解析もなし。", "Apple TV, iPhone, iPad, Mac을 위한 하나의 앱. 계정도, 분석도 없습니다.", "一個 App 支援 Apple TV、iPhone、iPad 與 Mac。免帳號、無分析追蹤。"],

  // Controls and page chrome
  "Play": ["再生", "재생", "播放"],
  "Pause": ["一時停止", "일시정지", "暫停"],
  "Replay": ["もう一度", "다시 보기", "重播"],
  "Seek": ["再生位置", "탐색", "播放位置"],
  "Yingxia introduction film": ["映匣の紹介動画", "Yingxia 소개 영상", "映匣介紹影片"],
  "How it works": ["仕組み", "작동 방식", "運作方式"],
  "How Yingxia works": ["映匣の仕組み", "Yingxia 작동 방식", "映匣如何運作"],
};

const COL: Record<Exclude<Lang, "en">, number> = { ja: 0, ko: 1, "zh-Hant": 2 };

/** The film string `en` in `lang`, or `en` itself when there is no translation. */
export function tr(lang: Lang, en: string): string {
  return lang === "en" ? en : T[en]?.[COL[lang]] ?? en;
}

export function translateFilm(root: HTMLElement, lang: Lang) {
  if (lang === "en") return;
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const [, lead, text, trail] = /^(\s*)([\s\S]*?)(\s*)$/.exec(n.nodeValue ?? "")!;
    if (!text) continue;
    const out = tr(lang, text);
    if (out === text) continue;
    n.nodeValue = lead + out + trail;
    // Typed lines step once per character.
    n.parentElement?.closest<HTMLElement>(".type")?.style.setProperty("--n", String([...out].length));
  }
  for (const el of root.querySelectorAll<HTMLElement>("[data-ch]")) el.dataset.ch = tr(lang, el.dataset.ch ?? "");
  for (const el of root.querySelectorAll<HTMLElement>("[aria-label]")) el.setAttribute("aria-label", tr(lang, el.getAttribute("aria-label")!));
}
