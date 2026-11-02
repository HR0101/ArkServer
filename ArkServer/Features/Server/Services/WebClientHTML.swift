import Foundation

// 外観の改善に unslop（Damir Sokolovsky / @heydamir、CC BY 4.0）を参照: https://heydamir.design/unslop
/// ブラウザ用クライアント（HTML/CSS/JS を1本の生文字列で持つ）。
/// iOS/Android 版と同じ「ホーム／ショート／アルバム」の3タブ構成で、
/// スマホ（下タブバー）と Mac（左サイドレール）でレイアウトを切り替える。
enum WebClientHTML {
    static let manifest = #"""
    {
      "name": "Ark Server",
      "short_name": "Ark Server",
      "description": "家庭内LANで動画と写真を閲覧するメディアサーバー",
      "start_url": "/#home",
      "scope": "/",
      "display": "standalone",
      "background_color": "#1B1B1B",
      "theme_color": "#1B1B1B",
      "icons": [
        { "src": "/pwa-icon.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
      ]
    }
    """#

    static let page = #"""
    <!DOCTYPE html>
    <html lang="ja">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
    <meta name="theme-color" content="#1B1B1B">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Ark Server">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/pwa-icon.png">
    <title>Ark Server</title>
    <style>
    :root {
        /* Mac アプリ本体と中立色の面・青いアクセントを共有する。
           Web のアクセント面には、文字のコントラストを確保するため濃色を載せる。 */
        --bg: #1B1B1B;      /* 内容側の下地 */
        --bg-1: #262626;    /* サイドバー・上部バー・カードの面 */
        --bg-2: #313131;    /* 面の上の入力欄・ホバー */
        --line: rgba(255,255,255,0.08);
        --accent: #5499FF;
        /* --accent から派生する色。出どころはここ1か所にし、--accent を変えたら4つとも合わせて直す。
           color-mix() で導出すると非対応ブラウザで hover などが無効になるため、固定値で持つ。 */
        --accent-hover: #69A5FF;
        --accent-pressed: #4D8DEB;
        --on-accent: var(--bg);
        --accent-soft: rgba(84,153,255,0.18);
        --accent-faint: rgba(84,153,255,0.12);
        --text: #EDEDED;
        --text-2: #9E9E9E;
        --text-3: rgba(255,255,255,0.38);
        /* 日本語の強調は500との差に依存せず、主要な操作・項目名・見出しに600を使う。 */
        --weight-medium: 500;
        --weight-semibold: 600;
        --select: rgba(255,255,255,0.11);   /* 選択中の行・ボタンの面（色は付けない） */
        --rail: 240px;
        --top: 56px;
        --tabbar: 56px;
        --safe-b: env(safe-area-inset-bottom, 0px);
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body { height: 100%; }
    body {
        margin: 0; background: var(--bg); color: var(--text);
        font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Noto Sans JP", "Segoe UI", Roboto, sans-serif;
        overscroll-behavior-y: none;
    }
    button { font-family: inherit; }
    button:disabled { cursor: default; opacity: 0.5; }
    .hidden { display: none !important; }
    svg.ico { width: 24px; height: 24px; fill: currentColor; display: block; }
    svg.ico-s { width: 18px; height: 18px; fill: currentColor; display: block; }

    /* ============ 上部バー ============ */
    .masthead {
        position: fixed; top: 0; left: 0; right: 0; height: var(--top); z-index: 60;
        display: flex; align-items: center; gap: 8px; padding: 0 12px;
        background: var(--bg-1);
        border-bottom: 1px solid var(--line);
    }
    .brand { display: flex; align-items: center; gap: 8px; font-weight: var(--weight-semibold); }
    .brand-mark {
        width: 28px; height: 20px; border-radius: 6px; background: var(--accent);
        display: grid; place-items: center; color: var(--on-accent);
    }
    .brand-mark svg { width: 12px; height: 12px; }
    .brand-text { font-size: 16px; color: var(--text); white-space: nowrap; }
    .masthead-spacer { flex: 1; }
    .search-wrap { flex: 0 1 520px; display: flex; align-items: center; }
    .search-box {
        display: flex; align-items: center; width: 100%; gap: 8px;
        background: var(--bg-1); border: 1px solid var(--line);
        border-radius: 999px; padding: 0 14px; height: 38px; color: var(--text-3);
    }
    .search-box:focus-within { border-color: var(--accent); color: var(--text); }
    .search-box input {
        flex: 1; background: transparent; border: none; outline: none;
        color: var(--text); font-size: 14px; min-width: 0;
    }
    .icon-btn {
        width: 40px; height: 40px; flex: none; border-radius: 50%; border: none;
        background: transparent; color: var(--text); display: grid; place-items: center; cursor: pointer;
    }
    .icon-btn:hover { background: rgba(255,255,255,0.09); }
    .icon-btn:active { background: rgba(255,255,255,0.16); }
    .icon-btn.spinning svg { animation: spin 0.8s linear infinite; }

    /* ============ ナビゲーション ============ */
    .nav { position: fixed; z-index: 55; background: var(--bg-1); }
    .nav-item {
        display: flex; align-items: center; border: none; background: transparent;
        color: var(--text-2); cursor: pointer; width: 100%;
    }
    .nav-item.active { color: var(--text); font-weight: var(--weight-semibold); }
    .nav-ico { display: grid; place-items: center; flex: none; }

    /* --- Mac / 広い画面: 左サイドレール --- */
    @media (min-width: 901px) {
        .nav {
            top: var(--top); bottom: 0; left: 0; width: var(--rail);
            border-right: 1px solid var(--line); padding: 12px 8px; overflow-y: auto;
        }
        .nav-item { gap: 20px; padding: 0 14px; height: 44px; border-radius: 10px; font-size: 14.5px; font-weight: var(--weight-medium); }
        .nav-item:hover { background: rgba(255,255,255,0.07); }
        .nav-item.active { background: var(--select); }
        .nav-item.active .nav-ico { color: var(--text); }
        .nav-foot { margin-top: 14px; padding: 14px 14px 0; border-top: 1px solid var(--line); color: var(--text-3); font-size: 11.5px; line-height: 1.7; }
        .content { margin-left: var(--rail); padding-top: var(--top); min-height: 100vh; }
        .mobile-only { display: none !important; }
    }
    /* 中間幅はアイコン中心のミニレール */
    @media (min-width: 901px) and (max-width: 1099px) {
        :root { --rail: 76px; }
        .nav { padding: 8px 4px; }
        .nav-item { flex-direction: column; gap: 5px; height: auto; padding: 14px 0; font-size: 10px; font-weight: var(--weight-medium); }
        .nav-foot { display: none; }
    }

    /* --- スマホ / 狭い画面: 下タブバー --- */
    @media (max-width: 900px) {
        .nav {
            left: 0; right: 0; bottom: 0; top: auto; display: flex;
            height: calc(var(--tabbar) + var(--safe-b));
            padding-bottom: var(--safe-b);
            border-top: 1px solid var(--line);
            background: var(--bg-1);
        }
        .nav-item { flex: 1; flex-direction: column; justify-content: center; gap: 3px; font-size: 10px; font-weight: var(--weight-medium); }
        .nav-item.active { color: var(--text); }
        .nav-foot { display: none; }
        .content { padding-top: var(--top); padding-bottom: calc(var(--tabbar) + var(--safe-b)); min-height: 100dvh; }
        .desktop-only { display: none !important; }
        .search-wrap { position: absolute; top: var(--top); left: 0; right: 0; padding: 10px 12px; background: var(--bg); border-bottom: 1px solid var(--line); }
        .search-wrap:not(.open) { display: none; }
        .brand-text { font-size: 15px; }
    }

    .tab-panel { display: none; }
    .tab-panel.active { display: block; }

    /* ============ 共通パーツ ============ */
    .state-box { display: grid; place-items: center; gap: 14px; padding: 80px 20px; color: var(--text-2); text-align: center; }
    .spinner { width: 34px; height: 34px; border: 3px solid rgba(255,255,255,0.14); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.9s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .thumb-fallback { background: repeating-linear-gradient(45deg, #1f1f1f, #1f1f1f 10px, #242424 10px, #242424 20px); }
    .pill {
        border: 1px solid var(--line); background: var(--bg-1); color: var(--text);
        border-radius: 999px; padding: 8px 16px; font-size: 13px; font-weight: var(--weight-semibold); cursor: pointer;
        display: inline-flex; align-items: center; gap: 6px; white-space: nowrap;
    }
    .btn-accent { background: var(--accent); color: var(--on-accent); border-color: transparent; }
    /* 中立のピルの hover・押下は、背景色を差し替えず白を重ねて出す。.danger や .on など状態色のピルにも同じ反応が付く。
       アクセントのボタンだけは、専用の色（--accent-hover / --accent-pressed）に差し替える。
       hover はマウス端末だけ（タッチで貼り付かせない）、:active はタッチでも効かせる。
       以下はすべて同じ詳細度なので、書く順番で勝敗が決まる: hover → 押下、中立 → アクセントの順に並べる。 */
    @media (hover: hover) {
        .pill:enabled:hover { box-shadow: inset 0 0 0 999px rgba(255,255,255,0.08); }
        .btn-accent:enabled:hover { background: var(--accent-hover); box-shadow: none; }
    }
    .pill:enabled:active { box-shadow: inset 0 0 0 999px rgba(255,255,255,0.16); }
    .btn-accent:enabled:active { background: var(--accent-pressed); box-shadow: none; }
    /* 映像上の補足は、同じ背景・文字・角丸で可読性を確保する。 */
    .chip-on-media {
        background: rgba(0,0,0,0.7); color: #fff;
        padding: 2px 6px; border-radius: 4px; font-weight: var(--weight-semibold);
        font-variant-numeric: tabular-nums; text-shadow: 0 1px 2px rgba(0,0,0,0.9);
    }
    .badge-dur { position: absolute; bottom: 6px; right: 6px; font-size: 11px; }
    .badge-photo { position: absolute; top: 6px; left: 6px; font-size: 10px; }

    /* キーボード操作のフォーカス表示（カードは div + role=button なので自前で出す） */
    [data-action]:focus-visible, .icon-btn:focus-visible, .pill:focus-visible, .select:focus-visible, .btn-accent:focus-visible {
        outline: 2px solid var(--accent); outline-offset: 2px;
    }
    [data-action]:not(button):focus-visible, .chapter:focus-visible { border-radius: 6px; }

    /* お気に入りのハート（サムネの左上） */
    .fav-badge {
        position: absolute; top: 6px; left: 6px; width: 24px; height: 24px; border-radius: 50%;
        background: rgba(0,0,0,0.6); display: grid; place-items: center; color: #FF453A; backdrop-filter: blur(4px);
    }
    .fav-badge svg { width: 14px; height: 14px; fill: currentColor; }
    .pill.fav-on { color: #FF453A; border-color: rgba(255,69,58,0.5); background: rgba(255,69,58,0.12); }
    .pill.on { background: rgba(255,255,255,0.16); color: var(--text); border-color: transparent; }

    /* 複数選択 */
    .sel-check {
        position: absolute; top: 6px; right: 6px; width: 24px; height: 24px; border-radius: 50%;
        border: 2px solid rgba(255,255,255,0.85); background: rgba(0,0,0,0.45); z-index: 2;
        display: grid; place-items: center; color: #fff;
    }
    .sel-check svg { width: 14px; height: 14px; fill: currentColor; opacity: 0; }
    .media-card.selected .sel-check { background: var(--accent); color: var(--on-accent); border-color: var(--accent); }
    .media-card.selected .sel-check svg { opacity: 1; }
    .media-card.selected .media-thumb { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent-soft); }
    .bulk-bar {
        display: flex; gap: 10px; align-items: center; flex-wrap: wrap;
        padding: 12px 14px; margin-bottom: 16px; border-radius: 14px;
        background: var(--bg-1); border: 1px solid var(--line);
    }
    .bulk-bar.hidden { display: none; }
    .bulk-count { font-size: 13px; font-weight: var(--weight-semibold); color: var(--text); }

    /* アップロード */
    .upload-bar {
        display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
        padding: 12px 14px; margin-bottom: 16px; border-radius: 14px;
        background: var(--bg-1); border: 1px solid var(--line);
    }
    .upload-bar.hidden { display: none; }
    .upload-text { font-size: 13px; font-weight: var(--weight-semibold); flex: 1 1 220px; min-width: 0; }
    .upload-track { flex: 1 1 160px; height: 8px; border-radius: 4px; background: rgba(255,255,255,0.14); overflow: hidden; }
    .upload-fill { height: 100%; width: 0%; background: var(--accent); transition: width 0.15s; }
    .dropzone { position: relative; }
    .dropzone.dragging::after {
        content: 'ここにドロップしてアップロード';
        position: absolute; inset: -8px; z-index: 30; border-radius: 16px;
        border: 2px dashed var(--accent); background: var(--accent-faint);
        display: grid; place-items: center; font-weight: var(--weight-semibold); color: var(--text); pointer-events: none;
    }

    /* アルバム選択・作成のシート */
    .sheet-list { display: flex; flex-direction: column; gap: 6px; margin-top: 4px; }
    .sheet-item {
        display: flex; align-items: center; gap: 10px; width: 100%; text-align: left;
        padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line);
        background: var(--bg-2); color: var(--text); font-size: 14px; cursor: pointer;
    }
    .sheet-item:hover { border-color: var(--accent); }
    .sheet-item .count { margin-left: auto; color: var(--text-3); font-size: 12px; }
    .field { margin-bottom: 14px; }
    .field label { display: block; font-size: 12px; color: var(--text-2); margin-bottom: 6px; font-weight: var(--weight-semibold); }
    .field input, .field select {
        width: 100%; background: var(--bg-2); border: 1px solid var(--line); color: var(--text);
        border-radius: 12px; padding: 12px 14px; font-size: 14px; outline: none;
    }
    .field input:focus, .field select:focus { border-color: var(--accent); }

    /* 詳細情報 */
    #info-modal, #picker-modal, #create-modal {
        display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.7);
        z-index: 120; justify-content: center; align-items: center; padding: 20px;
    }
    #info-modal.open, #picker-modal.open, #create-modal.open { display: flex; }
    .info-card {
        background: var(--bg-1); border: 1px solid var(--line); border-radius: 18px;
        width: 100%; max-width: 460px; max-height: 80vh; overflow-y: auto; padding: 22px;
    }
    .info-card h3 { margin: 0 0 16px; font-size: 17px; font-weight: var(--weight-semibold); }
    .info-row { display: flex; gap: 12px; padding: 9px 0; border-top: 1px solid var(--line); font-size: 13px; }
    .info-key { flex: 0 0 108px; color: var(--text-2); }
    .info-val { flex: 1; min-width: 0; word-break: break-word; }

    /* サムネ下端の視聴済みバー */
    .watched { position: absolute; left: 0; right: 0; bottom: 0; height: 4px; background: rgba(0,0,0,0.55); }
    .watched-fill { height: 100%; background: var(--accent); }

    /* 「続きを見る」タブ */
    .crow-empty { display: grid; place-items: center; gap: 10px; padding: 90px 20px; color: var(--text-2); text-align: center; }
    .crow-empty .big { font-size: 17px; font-weight: var(--weight-semibold); color: var(--text); }
    .cw-left { font-size: 12px; color: var(--text-2); margin-top: 4px; }

    /* ============ ホームフィード（「続きを見る」タブも同じ形） ============ */
    .feed { display: grid; }
    @media (min-width: 901px) {
        .feed { grid-template-columns: repeat(auto-fill, minmax(310px, 1fr)); gap: 38px 16px; padding: 24px; max-width: 1900px; margin: 0 auto; }
        .shelf { margin-left: -24px; margin-right: -24px; }
        .feed-thumb { border-radius: 14px; }
        .feed-meta { padding: 12px 0 0; }
    }
    @media (max-width: 900px) {
        .feed { grid-template-columns: minmax(0, 1fr); }
        .feed-card { padding-bottom: 20px; }
        .feed-meta { padding: 11px 12px 0; }
    }
    .feed-card { cursor: pointer; min-width: 0; }
    .feed-thumb { position: relative; width: 100%; aspect-ratio: 16 / 9; background: #000; overflow: hidden; }
    .feed-thumb img, .feed-thumb video { width: 100%; height: 100%; object-fit: cover; display: block; }
    .feed-thumb video { position: absolute; inset: 0; background: #000; }
    .feed-card:hover .feed-thumb { filter: brightness(1.06); }
    .feed-meta { display: flex; gap: 12px; align-items: flex-start; }
    .avatar {
        width: 36px; height: 36px; border-radius: 50%; flex: none;
        background: var(--bg-2); color: var(--text-2); display: grid; place-items: center;
        border: 1px solid var(--line);
    }
    .feed-text { min-width: 0; flex: 1; }
    .feed-title {
        font-size: 15px; font-weight: var(--weight-semibold); line-height: 1.35; color: var(--text);
        display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    }
    .feed-sub { font-size: 12.5px; color: var(--text-2); margin-top: 5px; line-height: 1.5; }

    /* ============ ショート棚 ============ */
    /* min-width:0 が無いとグリッド項目が中身（横スクロールの棚）まで広がり、ページ全体が横に伸びる */
    .shelf {
        grid-column: 1 / -1; min-width: 0; padding: 20px 0; margin: 6px 0;
        background: rgba(255,255,255,0.028);
        border-top: 1px solid var(--line); border-bottom: 1px solid var(--line);
    }
    .shelf-head { display: flex; align-items: center; gap: 9px; padding: 0 16px 14px; font-size: 17px; font-weight: var(--weight-semibold); }
    .shelf-head .ico { color: var(--text-2); }
    .shelf-row {
        display: flex; gap: 12px; overflow-x: auto; padding: 0 16px 6px;
        scroll-snap-type: x proximity; scroll-padding-left: 16px; -webkit-overflow-scrolling: touch;
        scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.2) transparent;
    }
    .shelf-row::-webkit-scrollbar { height: 6px; }
    .shelf-row::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.18); border-radius: 3px; }
    .short-card { flex: none; width: 148px; scroll-snap-align: start; cursor: pointer; }
    @media (min-width: 901px) { .short-card { width: 172px; } }
    .short-thumb { position: relative; width: 100%; aspect-ratio: 9 / 16; border-radius: 12px; overflow: hidden; background: #000; border: 1px solid var(--line); }
    .short-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .short-card:hover .short-thumb { border-color: rgba(255,255,255,0.3); }
    .short-title {
        margin-top: 8px; font-size: 12.5px; font-weight: var(--weight-semibold); line-height: 1.35; color: var(--text);
        display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    }

    /* ============ アルバム ============ */
    .page-pad { padding: 20px 16px 40px; max-width: 1900px; margin: 0 auto; }
    @media (min-width: 901px) { .page-pad { padding: 24px; } }
    .section-title {
        font-size: 14px; font-weight: var(--weight-semibold); color: var(--text);
        margin: 26px 0 12px;
    }
    .section-title:first-child { margin-top: 4px; }
    .album-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(148px, 1fr)); gap: 16px; }
    @media (min-width: 901px) { .album-grid { grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 20px; } }
    .album-card { cursor: pointer; }
    .album-thumb { position: relative; width: 100%; aspect-ratio: 1 / 1; border-radius: 16px; overflow: hidden; background: var(--bg-1); border: 1px solid var(--line); }
    .album-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .album-card:hover .album-thumb { border-color: rgba(255,255,255,0.3); }
    .album-empty { position: absolute; inset: 0; display: grid; place-items: center; color: var(--text-3); }
    .album-empty svg { width: 44px; height: 44px; }
    .album-count {
        position: absolute; bottom: 8px; right: 8px; font-size: 12px;
    }
    .album-name { margin-top: 9px; font-size: 13.5px; font-weight: var(--weight-semibold); line-height: 1.4; }
    .album-name.photo { color: var(--text); }

    .detail-head { display: flex; align-items: center; gap: 12px; margin-bottom: 18px; }
    .detail-title { font-size: 20px; font-weight: var(--weight-semibold); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .toolbar { display: flex; gap: 10px; margin-bottom: 20px; flex-wrap: wrap; align-items: center; }
    .select {
        background: var(--bg-1); border: 1px solid var(--line); color: var(--text);
        padding: 0 14px; height: 38px; border-radius: 999px; font-size: 13px; outline: none; cursor: pointer;
    }
    .select option { background: #1c1c28; }
    .media-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 14px; }
    @media (min-width: 901px) { .media-grid { grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 20px 16px; } }
    .media-card { cursor: pointer; min-width: 0; }
    .media-thumb { position: relative; width: 100%; border-radius: 12px; overflow: hidden; background: #000; border: 1px solid var(--line); }
    .media-grid.ratio-video .media-thumb { aspect-ratio: 16 / 9; }
    .media-grid.ratio-square .media-thumb { aspect-ratio: 1 / 1; }
    .media-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .media-card:hover .media-thumb { border-color: rgba(255,255,255,0.3); }
    .media-name {
        margin-top: 8px; font-size: 13px; font-weight: var(--weight-semibold); line-height: 1.4;
        display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    }

    /* ============ ショートタブ ============ */
    body.shorts-mode { overflow: hidden; }
    #panel-shorts.active { display: flex; align-items: center; justify-content: center; background: #000; position: relative; }
    @media (min-width: 901px) { #panel-shorts { height: calc(100vh - var(--top)); } }
    @media (max-width: 900px) {
        body.shorts-mode .masthead { display: none; }
        body.shorts-mode .content { padding-top: 0; }
        #panel-shorts { height: calc(100dvh - var(--tabbar) - var(--safe-b)); }
    }
    .shorts-stage { display: flex; align-items: center; gap: 18px; height: 100%; width: 100%; justify-content: center; }
    .shorts-frame { position: relative; background: #000; overflow: hidden; height: 100%; width: 100%; }
    @media (min-width: 901px) {
        .shorts-frame { height: calc(100% - 32px); width: auto; aspect-ratio: 9 / 16; border-radius: 16px; border: 1px solid var(--line); }
    }
    .shorts-frame video { width: 100%; height: 100%; object-fit: contain; display: block; transition: transform 0.12s; background: #000; }
    /* z-index を持たせないと、下の .shorts-tap（z-index:1）に覆われてシークバーを掴めない */
    .shorts-overlay { position: absolute; inset: auto 0 0 0; padding: 16px 16px 20px; pointer-events: none; z-index: 3;
        background: linear-gradient(to top, rgba(0,0,0,0.85), rgba(0,0,0,0.35) 55%, transparent); }
    @media (max-width: 900px) { .shorts-overlay { padding-right: 76px; } }
    /* 明るい映像でも読めるよう、件数・アルバム名の背後に一定の暗さを確保する。 */
    .shorts-count {
        display: block; width: fit-content; max-width: 100%; font-size: 12px; line-height: 1.5;
        overflow-wrap: anywhere;
    }
    .shorts-count:empty { display: none; }
    .shorts-title { font-size: 15px; font-weight: var(--weight-semibold); margin: 4px 0 10px; text-shadow: 0 2px 6px rgba(0,0,0,0.9);
        display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .shorts-bar {
        height: 8px; border-radius: 4px; background: rgba(255,255,255,0.25); cursor: pointer;
        pointer-events: auto; position: relative; transition: height 0.12s;
        touch-action: none;  /* ドラッグをブラウザのスクロール操作に取られないようにする */
    }
    /* 見た目は細いまま、指で掴める高さの当たり判定を足す */
    .shorts-bar::before { content: ''; position: absolute; left: 0; right: 0; top: -13px; bottom: -13px; }
    .shorts-bar.scrubbing { height: 12px; }
    .shorts-bar-fill { height: 100%; width: 0%; border-radius: 4px; background: rgba(255,255,255,0.92); pointer-events: none; }
    .shorts-bar-knob {
        position: absolute; top: 50%; left: 0; width: 16px; height: 16px; margin-left: -8px;
        border-radius: 50%; background: #fff; transform: translateY(-50%);
        pointer-events: none; box-shadow: 0 1px 5px rgba(0,0,0,0.6);
        opacity: 0; transition: opacity 0.12s;
    }
    .shorts-bar:hover .shorts-bar-knob, .shorts-bar.scrubbing .shorts-bar-knob { opacity: 1; }
    @media (hover: none) { .shorts-bar-knob { opacity: 1; } }
    .shorts-rail { position: absolute; right: 12px; bottom: 24px; display: flex; flex-direction: column; gap: 14px; z-index: 3; }
    @media (min-width: 901px) { .shorts-rail { position: static; justify-content: flex-end; padding-bottom: 24px; } }
    .rail-btn {
        width: 48px; height: 48px; border-radius: 50%; border: none; cursor: pointer;
        background: rgba(255,255,255,0.16); color: #fff; display: grid; place-items: center;
        backdrop-filter: blur(8px);
    }
    .rail-btn:hover { background: rgba(255,255,255,0.28); }
    .rail-btn.on { background: rgba(255,255,255,0.92); color: #000; }
    .shorts-tap { position: absolute; inset: 0; z-index: 1; }
    .shorts-pause {
        position: absolute; inset: 0; display: grid; place-items: center; pointer-events: none; z-index: 2;
        opacity: 0; transition: opacity 0.15s;
    }
    .shorts-pause.show { opacity: 1; }
    .shorts-pause svg { width: 74px; height: 74px; fill: rgba(255,255,255,0.9); filter: drop-shadow(0 4px 14px rgba(0,0,0,0.7)); }
    .shorts-zoom {
        position: absolute; right: 72px; bottom: 96px; z-index: 4; width: 210px; padding: 14px;
        background: rgba(30,30,30,0.96); border: 1px solid var(--line); border-radius: 14px;
    }
    @media (min-width: 901px) { .shorts-zoom { right: 12px; bottom: 110px; } }
    .shorts-zoom label { display: block; font-size: 12px; font-weight: var(--weight-semibold); margin-bottom: 10px; text-align: center; color: var(--text-2); }
    .shorts-zoom input { width: 100%; accent-color: var(--accent); }
    .shorts-zoom .hint { margin-top: 8px; font-size: 11px; line-height: 1.5; color: var(--text-3); text-align: center; }

    /* ============ 再生モーダル ============ */
    #player-modal { display: none; position: fixed; inset: 0; background: var(--bg); z-index: 90; }
    #player-modal.open { display: block; }
    .watch { height: 100%; }
    .stage { position: relative; width: 100%; background: #000; overflow: hidden; }
    .stage video, .stage img { width: 100%; height: 100%; object-fit: contain; display: block; outline: none; background: #000; }
    .playback-error {
        position: absolute; inset: 0; z-index: 3; display: flex; flex-direction: column;
        align-items: center; justify-content: center; gap: 12px; padding: 24px; text-align: center;
        background: radial-gradient(circle at center, rgba(40,40,40,0.96), rgba(0,0,0,0.96));
    }
    .playback-error.hidden { display: none; }
    .playback-error-title { font-size: 17px; font-weight: var(--weight-semibold); }
    .playback-error-message { max-width: 520px; color: var(--text-2); font-size: 13px; line-height: 1.7; }
    .playback-error-progress { color: var(--text-2); font-size: 12px; min-height: 18px; }
    .stage-close {
        position: absolute; top: 12px; left: 12px; z-index: 5; width: 40px; height: 40px; border-radius: 50%;
        border: none; background: rgba(0,0,0,0.55); color: #fff; display: grid; place-items: center; cursor: pointer; backdrop-filter: blur(6px);
    }
    .stage-close:hover { background: rgba(0,0,0,0.8); }
    .stage-mini, .stage-expand {
        position: absolute; top: 12px; right: 12px; z-index: 5; width: 40px; height: 40px;
        border-radius: 50%; border: none; background: rgba(0,0,0,0.55); color: #fff;
        display: grid; place-items: center; cursor: pointer; backdrop-filter: blur(6px);
    }
    .stage-expand { display: none; }
    .nav-arrow {
        position: absolute; top: 50%; transform: translateY(-50%); width: 46px; height: 74px; z-index: 4;
        background: rgba(0,0,0,0.35); color: #fff; border: none; cursor: pointer; border-radius: 8px;
        display: grid; place-items: center; opacity: 0; transition: opacity 0.2s; backdrop-filter: blur(4px);
        pointer-events: none;  /* 透明な状態でタップを奪わないようにする */
    }
    .stage:hover .nav-arrow { opacity: 1; pointer-events: auto; }
    .nav-arrow:hover { background: rgba(0,0,0,0.7); color: #fff; }
    .nav-arrow.prev { left: 14px; }
    .nav-arrow.next { right: 14px; }
    @media (hover: none) { .nav-arrow { display: none; } }
    /* 動画を10等分した地点のサムネ。押すとその位置へ飛ぶ。 */
    .chapters {
        display: flex; gap: 8px; overflow-x: auto; padding: 12px 16px 0;
        scroll-padding-left: 16px; -webkit-overflow-scrolling: touch;
        scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.2) transparent;
    }
    .chapters::-webkit-scrollbar { height: 6px; }
    .chapters::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.18); border-radius: 3px; }
    .chapters.hidden { display: none; }
    .chapter {
        flex: none; width: 96px; padding: 0; border: none; background: none;
        color: inherit; text-align: left; cursor: pointer; font: inherit;
    }
    .chapter-thumb {
        display: block; position: relative; width: 100%; aspect-ratio: 16 / 9;
        border-radius: 8px; overflow: hidden; background: #000; border: 1px solid var(--line);
    }
    .chapter-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .chapter-time {
        display: block; margin-top: 5px; font-size: 11px; font-weight: var(--weight-semibold);
        color: var(--text-2); font-variant-numeric: tabular-nums;
    }
    .chapter:hover .chapter-thumb { border-color: var(--accent); }
    .chapter.active .chapter-thumb { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent-soft); }
    .chapter.active .chapter-time { color: var(--text); }
    @media (min-width: 901px) {
        .chapters { padding: 14px 0 0; scroll-padding-left: 0; }
        .chapter { width: 116px; }
    }

    .watch-info { padding: 16px; }
    .watch-title { font-size: 17px; font-weight: var(--weight-semibold); line-height: 1.4; margin: 0; }
    .watch-sub { font-size: 12.5px; color: var(--text-2); margin-top: 6px; }
    .watch-actions { display: flex; gap: 10px; margin-top: 14px; flex-wrap: wrap; align-items: center; }
    .danger { background: rgba(255,69,58,0.16); border-color: rgba(255,69,58,0.5); color: #FF6B6B; }
    .watch-side { border-top: 1px solid var(--line); }
    .side-head { font-size: 13px; font-weight: var(--weight-semibold); color: var(--text-2); padding: 14px 16px 8px; }
    .un-item { display: flex; gap: 10px; padding: 8px 12px; cursor: pointer; align-items: flex-start; }
    .un-item:hover { background: rgba(255,255,255,0.05); }
    .un-item.current { background: var(--select); }
    .un-thumb { position: relative; width: 152px; flex: none; aspect-ratio: 16 / 9; border-radius: 8px; overflow: hidden; background: #000; }
    .un-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .un-info { min-width: 0; flex: 1; padding-top: 2px; }
    .un-title { font-size: 13px; line-height: 1.35; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .un-item.current .un-title { color: var(--text); font-weight: var(--weight-semibold); }
    .playing-label { color: var(--text); font-weight: var(--weight-semibold); }
    .un-meta { font-size: 11px; color: var(--text-2); margin-top: 4px; }

    @media (min-width: 901px) {
        /* 左（プレイヤー）と右（再生リスト）を別々にスクロールさせる。
           1つのスクロール領域にすると、リストを下に送っただけで動画が画面外へ逃げてしまう。 */
        .watch { display: flex; gap: 24px; padding: 20px; max-width: 1900px; margin: 0 auto;
                 height: 100%; overflow: hidden; }
        .watch-main { flex: 1 1 auto; min-width: 0; overflow-y: auto; }
        .stage { aspect-ratio: 16 / 9; max-height: calc(100vh - 190px); border-radius: 14px; }
        .watch-info { padding: 18px 2px 0; }
        .watch-title { font-size: 20px; }
        .watch-side { flex: 0 0 400px; border-top: none; border: 1px solid var(--line);
                      border-radius: 14px; overflow-y: auto; overscroll-behavior: contain; }
        .watch-side .side-head { position: sticky; top: 0; z-index: 1; background: var(--bg); }
    }
    @media (max-width: 900px) {
        .watch { display: flex; flex-direction: column; }
        .watch-main { flex: none; }
        .stage { aspect-ratio: 16 / 9; }
        .watch-side { flex: 1 1 auto; min-height: 0; overflow-y: auto; -webkit-overflow-scrolling: touch; padding-bottom: calc(20px + var(--safe-b)); }
        .un-thumb { width: 132px; }
    }
    #player-modal.mini {
        display: block; inset: auto 16px calc(var(--tabbar) + var(--safe-b) + 14px) auto;
        width: min(360px, calc(100vw - 32px)); height: auto; background: transparent;
        pointer-events: none; z-index: 85;
    }
    #player-modal.mini .watch { display: block; height: auto; padding: 0; overflow: visible; }
    #player-modal.mini .watch-main { overflow: visible; }
    #player-modal.mini .stage {
        width: 100%; aspect-ratio: 16 / 9; max-height: none; border-radius: 12px;
        pointer-events: auto; box-shadow: 0 16px 50px rgba(0,0,0,0.65); border: 1px solid var(--line);
    }
    #player-modal.mini .watch-info, #player-modal.mini .watch-side,
    #player-modal.mini .chapters, #player-modal.mini .nav-arrow, #player-modal.mini .stage-mini { display: none; }
    #player-modal.mini .stage-expand { display: grid; }
    @media (min-width: 901px) {
        #player-modal.mini { bottom: 20px; right: 20px; width: 360px; }
    }
    /* 写真は全画面ビューア（漫画モード対応） */
    #player-modal.mode-photo { background: #000; }
    #player-modal.mode-photo .watch { display: block; padding: 0; max-width: none; overflow: hidden; }
    #player-modal.mode-photo .watch-main { height: 100%; }
    #player-modal.mode-photo .stage { height: 100%; aspect-ratio: auto; max-height: none; border-radius: 0; }
    #player-modal.mode-photo .watch-side { display: none; }
    #player-modal.mode-photo .watch-info {
        position: absolute; top: 0; left: 0; right: 0; z-index: 4; padding: 12px 12px 12px 64px;
        background: linear-gradient(to bottom, rgba(0,0,0,0.8), transparent); pointer-events: none;
    }
    #player-modal.mode-photo .watch-title { font-size: 14px; -webkit-line-clamp: 1; display: -webkit-box; -webkit-box-orient: vertical; overflow: hidden; }
    #player-modal.mode-photo .watch-sub { display: none; }
    #player-modal.mode-photo .watch-actions { pointer-events: auto; margin-top: 10px; }

    /* ============ PIN ============ */
    #login-modal { display: none; position: fixed; inset: 0; background: rgba(27,27,27,0.98); z-index: 200; justify-content: center; align-items: center; }
    #login-modal.open { display: flex; }
    .login-card { background: var(--bg-1); border: 1px solid var(--line); border-radius: 20px; padding: 36px 28px; width: 90%; max-width: 340px; text-align: center; }
    .login-card > .ico { width: 32px; height: 32px; margin: 0 auto 12px; color: var(--text-2); }
    .login-card h2 { color: var(--text); margin: 0 0 8px; font-size: 20px; font-weight: var(--weight-semibold); }
    .login-card p { color: var(--text-2); font-size: 13px; margin: 0 0 22px; line-height: 1.6; }
    .pin-input { width: 100%; background: rgba(255,255,255,0.06); border: 1px solid var(--line); color: #fff; font-size: 24px; letter-spacing: 8px; text-align: center; padding: 14px; border-radius: 14px; outline: none; }
    .pin-input:focus { border-color: var(--accent); }
    /* 背景と文字色はここでも持つ（.btn-accent と併用して hover・押下の色を受ける）。クラスが外れても透明にならない。 */
    .login-btn { margin-top: 16px; width: 100%; background: var(--accent); color: var(--on-accent); font-weight: var(--weight-semibold); font-size: 16px; padding: 14px; border: none; border-radius: 14px; cursor: pointer; }
    .login-error { color: #FF6B6B; font-size: 13px; margin-top: 12px; min-height: 18px; }

    .toast {
        position: fixed; left: 50%; bottom: calc(var(--tabbar) + var(--safe-b) + 20px); transform: translateX(-50%);
        background: rgba(38,38,38,0.97); border: 1px solid var(--line); color: var(--text); padding: 12px 20px;
        border-radius: 999px; font-size: 13.5px; z-index: 300; opacity: 0; transition: opacity 0.25s; pointer-events: none;
    }
    .toast.show { opacity: 1; }
    #sync-dot {
        position: fixed; right: 12px; bottom: calc(var(--tabbar) + var(--safe-b) + 12px);
        width: 8px; height: 8px; border-radius: 50%; background: var(--text-2); opacity: 0;
        box-shadow: none; transition: opacity 0.2s; z-index: 299;
    }
    #sync-dot.on { opacity: 1; }
    @media (min-width: 901px) { .toast { bottom: 28px; } }
    </style>
    </head>
    <body>

    <!-- ================= 上部バー ================= -->
    <header class="masthead" id="masthead">
        <div class="brand">
            <span class="brand-mark"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></span>
            <span class="brand-text">Ark Server</span>
        </div>
        <div class="masthead-spacer desktop-only"></div>
        <div class="search-wrap" id="search-wrap">
            <div class="search-box">
                <svg class="ico-s" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14"/></svg>
                <input id="global-search" type="search" placeholder="タイトルで検索" autocomplete="off">
            </div>
        </div>
        <div class="masthead-spacer"></div>
        <button class="icon-btn mobile-only" id="search-toggle" title="検索">
            <svg class="ico" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14"/></svg>
        </button>
        <button class="icon-btn" id="refresh-btn" title="再読み込み">
            <svg class="ico" viewBox="0 0 24 24"><path d="M17.65 6.35A7.96 7.96 0 0 0 12 4a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4z"/></svg>
        </button>
        <button class="icon-btn" id="shutdown-btn" title="サーバーを終了">
            <svg class="ico" viewBox="0 0 24 24"><path d="M11 3h2v10h-2z"/><path d="M17.8 5.2 16.4 6.6A7 7 0 1 1 7.6 6.6L6.2 5.2a9 9 0 1 0 11.6 0"/></svg>
        </button>
    </header>

    <!-- ================= ナビ（Mac=左レール / スマホ=下タブ） ================= -->
    <nav class="nav" id="nav">
        <button class="nav-item active" data-tab="home" aria-current="page">
            <span class="nav-ico"><svg class="ico" viewBox="0 0 24 24"><path d="M12 3.1 2.6 11.2h2.9V21h5.1v-5.9h2.8V21h5.1v-9.8h2.9z"/></svg></span>
            <span class="nav-label">ホーム</span>
        </button>
        <button class="nav-item" data-tab="shorts">
            <span class="nav-ico"><svg class="ico" viewBox="0 0 24 24"><path d="M13.4 2.1c.5 2.7-.7 4.1-2.1 5.6-1.6 1.7-3.5 3.3-3.5 6.2a6.2 6.2 0 0 0 12.4 0c0-2.2-1-4.2-2.5-5.8.1 1.7-.5 3-1.7 3.7.8-3.8-1.1-7.4-2.6-9.7M11 14.4c.8.6 1.2 1.4 1.2 2.4 0 1.2-.8 2.2-1.9 2.5 1.3 1 3 .9 4.2-.2.8-.8 1.1-1.9.8-2.9-.6.4-1.3.5-2 .3.5-1.4-.8-2.4-2.3-2.1"/></svg></span>
            <span class="nav-label">ショート</span>
        </button>
        <button class="nav-item" data-tab="continue">
            <span class="nav-ico"><svg class="ico" viewBox="0 0 24 24"><path d="M4 3.5h16a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2m5.6 3v7l6-3.5z"/><rect x="2" y="19" width="20" height="2.6" rx="1.3" opacity=".35"/><rect x="2" y="19" width="11" height="2.6" rx="1.3"/></svg></span>
            <span class="nav-label">続きを見る</span>
        </button>
        <button class="nav-item" data-tab="albums">
            <span class="nav-ico"><svg class="ico" viewBox="0 0 24 24"><path d="M8 2h11a3 3 0 0 1 3 3v11h-2.2V5c0-.4-.4-.8-.8-.8H8z"/><path d="M4.5 6h11A2.5 2.5 0 0 1 18 8.5v11a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 2 19.5v-11A2.5 2.5 0 0 1 4.5 6"/></svg></span>
            <span class="nav-label">アルバム</span>
        </button>
        <div class="nav-foot desktop-only" id="nav-foot"></div>
    </nav>

    <!-- ================= 本体 ================= -->
    <main class="content" id="content">

        <section class="tab-panel active" id="panel-home">
            <div class="feed" id="home-feed"></div>
            <div id="home-sentinel" style="height:1px"></div>
            <div class="state-box" id="home-state"><div class="spinner"></div><div>読み込み中...</div></div>
        </section>

        <section class="tab-panel" id="panel-continue">
            <div class="feed" id="continue-feed"></div>
            <div class="state-box" id="continue-state"><div class="spinner"></div><div>読み込み中...</div></div>
        </section>

        <section class="tab-panel" id="panel-shorts">
            <div class="shorts-stage" id="shorts-stage">
                <div class="shorts-frame" id="shorts-frame">
                    <video id="shorts-video" playsinline webkit-playsinline preload="auto"></video>
                    <div class="shorts-tap" id="shorts-tap"></div>
                    <div class="shorts-pause" id="shorts-pause"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></div>
                    <div class="shorts-overlay">
                        <div class="shorts-count chip-on-media" id="shorts-count"></div>
                        <div class="shorts-title" id="shorts-title"></div>
                        <div class="shorts-bar" id="shorts-bar">
                            <div class="shorts-bar-fill" id="shorts-bar-fill"></div>
                            <div class="shorts-bar-knob" id="shorts-bar-knob"></div>
                        </div>
                    </div>
                    <div class="shorts-rail mobile-only" id="shorts-rail-m"></div>
                </div>
                <div class="shorts-rail desktop-only" id="shorts-rail-d"></div>
            </div>
            <div class="state-box" id="shorts-state" style="position:absolute"><div class="spinner"></div><div>読み込み中...</div></div>
        </section>

        <section class="tab-panel" id="panel-albums">
            <div class="page-pad" id="albums-list"></div>
            <div class="page-pad hidden dropzone" id="album-detail">
                <div class="detail-head">
                    <button class="icon-btn" id="detail-back" title="戻る">
                        <svg class="ico" viewBox="0 0 24 24"><path d="M20 11H7.8l5.6-5.6L12 4l-8 8 8 8 1.4-1.4L7.8 13H20z"/></svg>
                    </button>
                    <div class="detail-title" id="detail-title"></div>
                </div>
                <div class="toolbar">
                    <select class="select" id="sort-select">
                        <option value="importDesc">追加日が新しい順</option>
                        <option value="importAsc">追加日が古い順</option>
                        <option value="creationDesc">撮影日が新しい順</option>
                        <option value="creationAsc">撮影日が古い順</option>
                        <option value="durationDesc">長さが長い順</option>
                        <option value="durationAsc">長さが短い順</option>
                        <option value="nameAsc">名前順</option>
                        <option value="sizeDesc">サイズが大きい順</option>
                        <option value="sizeAsc">サイズが小さい順</option>
                        <option value="modifiedDesc">更新日が新しい順</option>
                        <option value="modifiedAsc">更新日が古い順</option>
                        <option value="lastOpenedDesc">最後に開いた順</option>
                    </select>
                    <button class="pill btn-accent" id="album-shorts-btn">
                        <svg class="ico-s" viewBox="0 0 24 24"><path d="M13.4 2.1c.5 2.7-.7 4.1-2.1 5.6-1.6 1.7-3.5 3.3-3.5 6.2a6.2 6.2 0 0 0 12.4 0c0-2.2-1-4.2-2.5-5.8.1 1.7-.5 3-1.7 3.7.8-3.8-1.1-7.4-2.6-9.7"/></svg>
                        ショート再生
                    </button>
                    <button class="pill" id="rename-album-btn">名前を変更</button>
                    <button class="pill danger" id="delete-album-btn">アルバムを削除</button>
                    <button class="pill danger hidden" id="empty-trash-btn">ゴミ箱を空にする</button>
                    <button class="pill danger hidden" id="empty-trash-system-btn">実ファイルをMacのゴミ箱へ</button>
                    <button class="pill" id="select-btn">選択</button>
                    <button class="pill" id="upload-btn">アップロード</button>
                    <input type="file" id="file-input" multiple class="hidden"
                           accept=".mp4,.mov,.m4v,.avi,.jpg,.jpeg,.png,.heic,.webp,.gif,.tiff">
                    <span id="detail-count" style="color:var(--text-3); font-size:12.5px"></span>
                </div>
                <div class="upload-bar hidden" id="upload-bar">
                    <div class="upload-text" id="upload-text"></div>
                    <div class="upload-track"><div class="upload-fill" id="upload-fill"></div></div>
                    <button class="pill" id="upload-cancel">中止</button>
                </div>
                <div class="bulk-bar hidden" id="bulk-bar">
                    <span class="bulk-count" id="bulk-count">0 件</span>
                    <button class="pill" id="bulk-all">すべて選択</button>
                    <button class="pill" id="bulk-fav">お気に入り</button>
                    <button class="pill" id="bulk-move">移動</button>
                    <button class="pill" id="bulk-trash">ゴミ箱へ</button>
                    <button class="pill btn-accent hidden" id="bulk-restore">復元</button>
                    <button class="pill danger" id="bulk-purge">完全に削除</button>
                    <button class="pill danger" id="bulk-system-trash">実ファイルをMacのゴミ箱へ</button>
                    <button class="pill" id="bulk-cancel">やめる</button>
                </div>
                <div class="media-grid ratio-video" id="media-grid"></div>
                <div id="album-sentinel" style="height:1px"></div>
            </div>
        </section>
    </main>

    <!-- ================= 再生モーダル ================= -->
    <div id="player-modal">
        <div class="watch">
            <div class="watch-main">
                <div class="stage" id="stage">
                    <button class="stage-close" id="stage-close" title="閉じる">
                        <svg class="ico" viewBox="0 0 24 24"><path d="M19 6.4 17.6 5 12 10.6 6.4 5 5 6.4l5.6 5.6L5 17.6 6.4 19l5.6-5.6 5.6 5.6 1.4-1.4-5.6-5.6z"/></svg>
                    </button>
                    <button class="stage-mini" id="stage-mini" title="ミニプレイヤー">
                        <svg class="ico-s" viewBox="0 0 24 24"><path d="M4 5h16v14H4zm9 7v5h5v-5z"/></svg>
                    </button>
                    <button class="stage-expand" id="stage-expand" title="プレイヤーを開く">
                        <svg class="ico-s" viewBox="0 0 24 24"><path d="M4 4h7v2H6v5H4zm9 0h7v7h-2V6h-5zM4 13h2v5h5v2H4zm14 0h2v7h-7v-2h5z"/></svg>
                    </button>
                    <button class="nav-arrow prev" id="arrow-prev"><svg class="ico" viewBox="0 0 24 24"><path d="M15.4 7.4 14 6l-6 6 6 6 1.4-1.4-4.6-4.6z"/></svg></button>
                    <button class="nav-arrow next" id="arrow-next"><svg class="ico" viewBox="0 0 24 24"><path d="M8.6 16.6 10 18l6-6-6-6-1.4 1.4 4.6 4.6z"/></svg></button>
                    <div class="playback-error hidden" id="playback-error">
                        <div class="playback-error-title" id="playback-error-title">再生できませんでした</div>
                        <div class="playback-error-message" id="playback-error-message"></div>
                        <div class="playback-error-progress" id="playback-error-progress"></div>
                        <button class="pill btn-accent" id="convert-btn">1080pへ変換して再生</button>
                    </div>
                </div>
                <div class="chapters hidden" id="chapters"></div>
                <div class="watch-info">
                    <h2 class="watch-title" id="watch-title"></h2>
                    <div class="watch-sub" id="watch-sub"></div>
                    <div class="watch-actions" id="playback-actions">
                        <button class="pill" id="autoplay-btn" title="再生が終わったら次へ進むか">自動再生</button>
                        <button class="pill" id="repeat-btn" title="リピート（なし → 1本 → 全体）">リピート: なし</button>
                        <button class="pill" id="shuffle-btn" title="次の動画をランダムに選ぶ">シャッフル</button>
                        <select class="select" id="rate-select" title="再生速度">
                            <option value="0.5">0.5倍</option>
                            <option value="0.75">0.75倍</option>
                            <option value="1" selected>等倍</option>
                            <option value="1.25">1.25倍</option>
                            <option value="1.5">1.5倍</option>
                            <option value="2">2倍</option>
                        </select>
                        <button class="pill" id="pip-btn" title="ピクチャインピクチャ">PiP</button>
                    </div>
                    <div class="watch-actions">
                        <select class="select" id="quality-select">
                            <option value="original">オリジナル画質</option>
                            <option value="1080p" selected>1080p（軽量）</option>
                            <option value="540p">540p（節約）</option>
                        </select>
                        <button class="pill" id="fav-btn">お気に入り</button>
                        <button class="pill" id="queue-btn">次に再生</button>
                        <button class="pill" id="playlist-btn">プレイリストに追加</button>
                        <button class="pill" id="share-btn">リンクをコピー</button>
                        <button class="pill" id="download-btn">ダウンロード</button>
                        <button class="pill" id="info-btn">詳細情報</button>
                        <button class="pill" id="manga-toggle">通常モード</button>
                        <button class="pill" id="watch-shorts">ショートで見る</button>
                        <button class="pill" id="trash-btn">ゴミ箱へ</button>
                        <button class="pill btn-accent hidden" id="restore-btn">ゴミ箱から復元</button>
                        <button class="pill danger" id="purge-btn">完全に削除</button>
                        <button class="pill danger" id="system-trash-btn">実ファイルをMacのゴミ箱へ</button>
                    </div>
                </div>
            </div>
            <aside class="watch-side" id="up-next"></aside>
        </div>
    </div>

    <div id="login-modal">
        <div class="login-card">
            <svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path fill-rule="evenodd" d="M18 8h-1V6a5 5 0 0 0-10 0v2H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V10a2 2 0 0 0-2-2zm-6 9a2 2 0 1 1 0-4 2 2 0 0 1 0 4zM9 8V6a3 3 0 0 1 6 0v2z"/></svg>
            <h2>PIN認証</h2>
            <p>このサーバーは保護されています。<br>Macの画面に表示されているPINを入力してください。</p>
            <input type="password" inputmode="numeric" class="pin-input" id="pin-input" placeholder="••••••" maxlength="12">
            <button class="login-btn btn-accent" id="login-btn">ロック解除</button>
            <div class="login-error" id="login-error"></div>
        </div>
    </div>

    <div id="picker-modal">
        <div class="info-card">
            <h3 id="picker-title">移動先のアルバム</h3>
            <div class="sheet-list" id="picker-list"></div>
            <button class="pill" id="picker-close" style="margin-top:18px; width:100%; justify-content:center">やめる</button>
        </div>
    </div>

    <div id="create-modal">
        <div class="info-card">
            <h3>新しいアルバム</h3>
            <div class="field">
                <label for="create-name">アルバム名</label>
                <input id="create-name" type="text" maxlength="80" placeholder="例: 旅行 2026" autocomplete="off">
            </div>
            <div class="field">
                <label for="create-type">種類</label>
                <select id="create-type">
                    <option value="video">動画アルバム</option>
                    <option value="photo">写真アルバム</option>
                    <option value="mixed">動画と写真</option>
                </select>
            </div>
            <div style="display:flex; gap:10px">
                <button class="pill" id="create-cancel" style="flex:1; justify-content:center">やめる</button>
                <button class="pill btn-accent" id="create-ok" style="flex:1; justify-content:center">作成</button>
            </div>
            <div class="login-error" id="create-error"></div>
        </div>
    </div>

    <div id="info-modal">
        <div class="info-card">
            <h3 id="info-title">詳細情報</h3>
            <div id="info-body"></div>
            <button class="pill" id="info-close" style="margin-top:18px; width:100%; justify-content:center">閉じる</button>
        </div>
    </div>

    <div class="toast" id="toast"></div>
    <div id="sync-dot" title="同期待ち"></div>

    <script>
    "use strict";

    // ======================= 状態 =======================
    var SHORTS_CLIP = 60;          // ショート1本の長さ（秒）— iOS/Android版と同じ
    var SHORT_MAX_DURATION = 60;   // 「ショート棚」に載せる動画の最大長
    var ALL_MEDIA_TTL = 60000;     // 全件リストのキャッシュ寿命（ミリ秒）
    var FEED_CHUNK = 12;
    var SHELF_SIZE = 15;           // 棚1枚に並べるショートの本数
    var CHAPTER_COUNT = 10;        // 再生画面の下に出す「10等分」サムネの枚数
    var CHAPTER_MIN_DURATION = 20; // これより短い動画では出さない（秒）

    var state = {
        tab: 'home',
        albums: [],
        allVideos: [],
        allVideosAt: 0,
        allPhotos: [],
        allPhotosAt: 0,
        trash: [],
        trashAt: 0,
        homeAll: [],        // シャッフル済み全動画
        homeFiltered: [],   // 検索適用後（フィードと再生リストの実体）
        homeRendered: 0,
        shortsDeck: [],     // 棚に配るショートの山札（描画中は固定）
        shelfPlan: {},      // 棚を挟むフィード位置
        shelfOrdinal: 0,    // 何枚目の棚か（山札を切り出す位置に使う）
        feedCols: 1,
        currentAlbum: null,
        albumRaw: [],
        albumFiltered: [],
        playerOrigin: null,
        playerIndex: 0,
        playbackFailed: false,   // 現在の動画が再生エラー中か（再生リストの「再生中」ラベルの出し分け用）
        isPlayerMini: false,
        queue: [],
        chapterTimes: [],   // 10等分サムネの各時刻（秒）
        chapterToken: 0,    // 動画を切り替えたら古い読み込みを打ち切るための番号
        quality: '1080p',
        progress: {},       // {videoID: {t: 秒, at: 最後に見た時刻}}
        // --- サーバー同期（websync.json）---
        favMarks: {},       // {videoID: {on, at}} お気に入りの正本。外した記録(on:false)も残す
        shortsFavMarks: {}, // {videoID: {on, t, at}} ショートお気に入りの正本
        syncDirty: false,   // サーバーへ送り残しがあるか
        syncSending: false, // PUT が飛んでいる最中か（同時発射を防ぐ）
        syncGeneration: 0,  // PUT中に追加更新されたかを判定する世代番号
        syncLastPushAt: 0,  // 直近の PUT 開始時刻。timeupdate の嵐で毎秒送らないための床
        syncLastPullAt: 0,  // 直近の GET 完了時刻
        syncBackoff: 0,     // 失敗時のバックオフ（ミリ秒）
        favorites: [],      // お気に入りのID（新しい順）。favMarks からの派生。直接 push/splice しない。変更は toggleFavorite 経由
        history: [],        // [{id, at}] 最後に開いた順
        historyRemoved: {}, // {videoID: 削除時刻} 他端末の古い履歴による復活を防ぐ
        shortsFavs: [],     // [{id, t, at}] shortsFavMarks からの派生。直接 push/splice しない。変更は toggleShortsFav 経由
        continueList: [],   // 「続きを見る」タブの再生リスト
        playback: { autoplay: true, repeat: 'off', shuffle: false, rate: 1, volume: 1, muted: false },
        playedStack: [],    // シャッフル中に「前へ」で辿るための履歴
        maxUploadBytes: 0,  // /server/status から取得（アップロード前のサイズ判定に使う）
        selectMode: false,
        selected: [],       // アルバム詳細で選択中のID
        albumRendered: 0,   // アルバム詳細の遅延描画で描き終えた件数
        mangaMode: localStorage.getItem('isMangaMode') === 'true',
        shortsPool: [],
        shortsIndex: 0,
        shortsClipStart: 0,
        shortsSource: '',
        shortsMuted: localStorage.getItem('shortsMuted') !== 'false',
        shortsZoom: parseInt(localStorage.getItem('shortsZoom') || '0', 10),
        shortsReady: false,
        isScrubbing: false,   // ショートのシークバーをドラッグ中か
        loading: false
    };

    var canHover = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
    var isDesktop = function () { return window.innerWidth >= 901; };
    function el(id) { return document.getElementById(id); }

    // ======================= ユーティリティ =======================
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    }

    // ファイル名から拡張子・UUID・連番などを落として読みやすいタイトルにする（iOS版 cleanVideoTitle と同じ狙い）
    function cleanTitle(name) {
        var t = String(name || '').replace(/\.[^.\/\\]+$/, '');
        var orig = t;
        t = t.replace(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, ' ');
        t = t.replace(/(^|[^A-Za-z0-9])(LINE_ALBUM_|IMG_|VID_|MVI_|DSC_|RPReplay_)/gi, '$1');
        t = t.replace(/(^|[^A-Za-z0-9])\d{6,}(?=[^A-Za-z0-9]|$)/g, '$1 ');
        t = t.replace(/_{2,}/g, '_').replace(/-{2,}/g, '-');
        t = t.replace(/\s+/g, ' ').replace(/^[\s_\-~〜\[\]()]+|[\s_\-~〜\[\]()]+$/g, '');
        return t || orig;
    }

    function formatDur(sec) {
        if (!sec || !isFinite(sec) || sec < 0) return '0:00';
        var total = Math.floor(sec), h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
        var pad = function (n) { return (n < 10 ? '0' : '') + n; };
        return h > 0 ? h + ':' + pad(m) + ':' + pad(s) : m + ':' + pad(s);
    }

    function timeAgo(iso) {
        if (!iso) return '';
        var d = new Date(iso);
        if (isNaN(d.getTime())) return '';
        var diff = (Date.now() - d.getTime()) / 1000;
        if (diff < 60) return 'たった今';
        if (diff < 3600) return Math.floor(diff / 60) + '分前';
        if (diff < 86400) return Math.floor(diff / 3600) + '時間前';
        if (diff < 2592000) return Math.floor(diff / 86400) + '日前';
        if (diff < 31536000) return Math.floor(diff / 2592000) + 'か月前';
        return Math.floor(diff / 31536000) + '年前';
    }

    // ======================= サーバー同期（websync.json） =======================
    // 揃えるのは「その動画が自分にとって何か」＝視聴位置・お気に入り・履歴だけ。
    // localStorage は今までどおり書き込みキャッシュとして残し、全ミューテーションは
    // 同期的にそこへ書いたうえで dirty フラグを立てるだけにする。サーバーが落ちていても
    // 送信に失敗しても、アプリの挙動は同期を入れる前とまったく同じに退化する。
    var SYNC_KEY_MIGRATED = 'mms_sync_migrated';
    var SYNC_DEBOUNCE = 2000;      // 旧 scheduleProgressSave と同じ間隔。書き込みの体感を変えないため
    var SYNC_MIN_INTERVAL = 5000;  // PUT の発射間隔の下限。timeupdate の嵐で毎秒送らないための床
    var SYNC_PULL_TTL = 30000;     // タブに戻ったとき、これより古ければ引き直す
    var SYNC_BACKOFF_MAX = 60000;
    var syncPushTimer = null;

    function syncHasOwn(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

    /// サーバーへ送る「クライアントの全体像」。再生の設定（音量・速度など）は端末に閉じるので入れない。
    function buildSyncDoc() {
        return {
            schemaVersion: 1,
            progress: state.progress,
            favorites: state.favMarks,
            history: state.history,
            historyRemoved: state.historyRemoved,
            shortsFavs: state.shortsFavMarks
        };
    }

    /// favMarks から state.favorites（on:true を at 降順）を作り直す
    function rebuildFavorites() {
        var out = [], id;
        for (id in state.favMarks) {
            if (!syncHasOwn(state.favMarks, id)) continue;
            if (state.favMarks[id] && state.favMarks[id].on) out.push(id);
        }
        out.sort(function (a, b) { return (state.favMarks[b].at || 0) - (state.favMarks[a].at || 0); });
        state.favorites = out;
    }

    /// shortsFavMarks から state.shortsFavs（[{id,t,at}] を at 降順）を作り直す
    function rebuildShortsFavs() {
        var out = [], id, m;
        for (id in state.shortsFavMarks) {
            if (!syncHasOwn(state.shortsFavMarks, id)) continue;
            m = state.shortsFavMarks[id];
            if (m && m.on) out.push({ id: id, t: m.t || 0, at: m.at || 0 });
        }
        out.sort(function (a, b) { return b.at - a.at; });
        state.shortsFavs = out;
    }

    /// サーバーから受け取った内容を取り込む。置き換えではなく必ずマージする。
    /// これがないと「サーバーが空／取得失敗のときローカルが消える」を防げない。
    /// 規則はサーバー側 WebSyncStore.merge と同じ、キー単位の LWW（at の大きい方が勝つ）。
    function mergeSyncDoc(remote) {
        if (!remote || typeof remote !== 'object') return false;
        var changed = false, id, r, l, i, e;

        var rp = remote.progress || {};
        for (id in rp) {
            if (!syncHasOwn(rp, id)) continue;
            r = rp[id]; if (!r) continue;
            l = state.progress[id];
            if (!l || (r.at || 0) > (l.at || 0)) {
                state.progress[id] = { t: r.t || 0, at: r.at || 0 };
                changed = true;
            }
        }

        var rf = remote.favorites || {};
        for (id in rf) {
            if (!syncHasOwn(rf, id)) continue;
            r = rf[id]; if (!r) continue;
            l = state.favMarks[id];
            if (!l || (r.at || 0) > (l.at || 0)) {
                state.favMarks[id] = { on: !!r.on, at: r.at || 0 };
                changed = true;
            }
        }

        var rs = remote.shortsFavs || {};
        for (id in rs) {
            if (!syncHasOwn(rs, id)) continue;
            r = rs[id]; if (!r) continue;
            l = state.shortsFavMarks[id];
            if (!l || (r.at || 0) > (l.at || 0)) {
                state.shortsFavMarks[id] = { on: !!r.on, t: r.t || 0, at: r.at || 0 };
                changed = true;
            }
        }

        var rr = remote.historyRemoved || {};
        for (id in rr) {
            if (!syncHasOwn(rr, id)) continue;
            if (!syncHasOwn(state.historyRemoved, id) || (rr[id] || 0) > (state.historyRemoved[id] || 0)) {
                state.historyRemoved[id] = rr[id] || 0;
                changed = true;
            }
        }

        // 履歴は id ごとの max(at) を集め，それより新しい削除記録がある項目を除外する。
        var rh = remote.history || [];
        var best = {}, hChanged = changed;
        for (i = 0; i < state.history.length; i++) {
            e = state.history[i];
            if (!e || !e.id) continue;
            if ((state.historyRemoved[e.id] || 0) >= (e.at || 0)) continue;
            if (!syncHasOwn(best, e.id) || (e.at || 0) > best[e.id]) best[e.id] = e.at || 0;
        }
        for (i = 0; i < rh.length; i++) {
            e = rh[i];
            if (!e || !e.id) continue;
            if ((state.historyRemoved[e.id] || 0) >= (e.at || 0)) continue;
            if (!syncHasOwn(best, e.id) || (e.at || 0) > best[e.id]) { best[e.id] = e.at || 0; hChanged = true; }
        }
        if (hChanged) {
            var order = [];
            for (id in best) {
                if (!syncHasOwn(best, id)) continue;
                order.push({ id: id, at: best[id] });
            }
            order.sort(function (a, b) { return b.at - a.at; });
            if (order.length > HISTORY_MAX) order.length = HISTORY_MAX;
            state.history = order;
            changed = true;
        }

        if (changed) { rebuildFavorites(); rebuildShortsFavs(); }
        return changed;
    }

    /// localStorage へ書き戻す。お気に入り2種はマップ形で保存する（旧配列形は migrateLocalSync でしか読まない）。
    function persistLocal() {
        // 視聴位置はトゥームストーン（t:0）も残す方式なので単調に増える。ここで古いものから捨てる。
        var ids = Object.keys(state.progress);
        if (ids.length > PROGRESS_MAX) {
            ids.sort(function (a, b) { return (state.progress[b].at || 0) - (state.progress[a].at || 0); });
            var trimmed = {};
            for (var i = 0; i < PROGRESS_MAX; i++) trimmed[ids[i]] = state.progress[ids[i]];
            state.progress = trimmed;
        }
        writeJSON(PROGRESS_KEY, state.progress);
        writeJSON(FAV_KEY, state.favMarks);
        writeJSON(HISTORY_KEY, state.history);
        writeJSON(HISTORY_REMOVED_KEY, state.historyRemoved);
        writeJSON(SHORTFAV_KEY, state.shortsFavMarks);
    }

    /// 送り残しがあることを右下の小さな点で示す。トーストだと LAN が揺れるたびに鳴って邪魔になる。
    function updateSyncDot() {
        var dot = el('sync-dot');
        if (dot) dot.classList.toggle('on', !!state.syncDirty);
    }

    /// すべてのミューテーションはここを通す。保存経路を1本にしないと、
    /// 「localStorage だけ書けてサーバーには送られていない」状態の切り分けができなくなる。
    function markDirty() {
        state.syncDirty = true;
        state.syncGeneration++;
        persistLocal();
        updateSyncDot();
        scheduleSyncPush();
    }

    function scheduleSyncPush() {
        if (syncPushTimer) return;
        var wait = SYNC_DEBOUNCE;
        var floor = state.syncLastPushAt + SYNC_MIN_INTERVAL - Date.now();
        if (floor > wait) wait = floor;
        if (state.syncBackoff > wait) wait = state.syncBackoff;
        syncPushTimer = setTimeout(function () {
            syncPushTimer = null;
            // 送信中なら重ねて撃たず、次の機会に回す（返ってきた結果で dirty が落ちる）
            if (state.syncSending) { scheduleSyncPush(); return; }
            pushSync(false);
        }, wait);
    }

    /// 全体像を PUT し、返ってきたマージ結果を取り込む。
    /// 応答がマージ結果なので、PUT の直後に GET し直す必要がない（往復が半分になる）。
    /// 失敗してもトーストは出さない。LAN が揺れるたびに通知が鳴る方が、同期していないことより不快。
    function pushSync(force) {
        if (!state.syncDirty) return;   // 送るものが無ければ何もしない
        if (state.syncSending) return;  // 同時発射を防ぐ
        if (!force && Date.now() - state.syncLastPushAt < SYNC_MIN_INTERVAL) { scheduleSyncPush(); return; }
        if (syncPushTimer) { clearTimeout(syncPushTimer); syncPushTimer = null; }
        state.syncSending = true;
        state.syncLastPushAt = Date.now();
        var sentGeneration = state.syncGeneration;
        api('/sync', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(buildSyncDoc())
        }).then(function (r) { return r.json(); }).then(function (merged) {
            state.syncSending = false;
            // PUT中に別のtimeupdate等が走っていれば、その更新は送信本文に入っていない。
            state.syncDirty = state.syncGeneration !== sentGeneration;
            state.syncBackoff = 0;
            state.syncLastPullAt = Date.now();  // マージ結果を受け取った＝引き直したのと同じ
            var changed = mergeSyncDoc(merged);
            if (changed) {
                persistLocal();
                // 一覧は作り直さず重ね物だけ差し替えるので、後追い反映でもスクロール位置が飛ばない
                refreshCardOverlays();
                if (state.tab === 'continue') renderContinue();
            }
            updateSyncDot();
            if (state.syncDirty) scheduleSyncPush();
        }).catch(function (err) {
            state.syncSending = false;
            // AuthError は api() がログインモーダルを出しているので、ここでは何もしない
            if (!(err instanceof AuthError)) {
                state.syncBackoff = state.syncBackoff ? Math.min(state.syncBackoff * 2, SYNC_BACKOFF_MAX) : SYNC_DEBOUNCE;
                scheduleSyncPush();
            }
            updateSyncDot();
        });
    }

    /// サーバーの内容を引き寄せてマージする。失敗は無視（ローカルのまま動く）。
    function pullSync() {
        return api('/sync').then(function (r) { return r.json(); }).then(function (remote) {
            state.syncLastPullAt = Date.now();
            var changed = mergeSyncDoc(remote);
            persistLocal();
            if (changed) {
                refreshCardOverlays();
                if (state.tab === 'continue') renderContinue();
            }
            return changed;
        }).catch(function () { return false; });
    }

    /// ページ離脱時の最後の1回。unload では fetch が中断されるので beacon しか通せない。
    /// ヘッダを付けられないため PIN は cookie 頼り（submitPIN が入れている）。
    function flushSyncBeacon() {
        if (!state.syncDirty || !navigator.sendBeacon) return;
        try {
            var blob = new Blob([JSON.stringify(buildSyncDoc())], { type: 'application/json' });
            navigator.sendBeacon('/sync', blob);
        } catch (e) {}
    }

    // ======================= localStorage の小道具 =======================
    function readJSON(key, fallback) {
        try {
            var v = JSON.parse(localStorage.getItem(key));
            return (v === null || v === undefined) ? fallback : v;
        } catch (e) { return fallback; }
    }
    function writeJSON(key, value) {
        try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {}
    }

    // ======================= お気に入り / 履歴 =======================
    var FAV_KEY = 'mms_favorites';
    var HISTORY_KEY = 'mms_history';
    var HISTORY_REMOVED_KEY = 'mms_history_removed';
    var SHORTFAV_KEY = 'mms_shorts_favorites';
    var HISTORY_MAX = 200;
    var MIGRATION_AT_BASE = 1; // わざとほぼ epoch。移行分は「後の明示操作に必ず負ける」

    /// 旧形式（裸の配列）のお気に入りを {id:{on,at}} のマップへ移す。
    /// 配列だと「相手がまだ知らない」と「相手が外した」を区別できず、片方で外したお気に入りが
    /// もう片方の古い配列で復活する。移行分に極端に古い at を振るのが要で、Date.now() を振ると
    /// 「PC で昔つけたお気に入り」が「スマホで昨日外した記録」に勝って復活してしまう。
    /// 読んだ値が配列かどうかで判断するので、フラグだけ先に立つ事故が起きても取りこぼさない。
    function migrateLocalSync() {
        var fav = readJSON(FAV_KEY, null);
        if (Array.isArray(fav)) {
            var marks = {};
            for (var i = 0; i < fav.length; i++) {
                // 降順（新しい順）の並びを at の降順として保ったまま、全体を極端に古くする
                if (typeof fav[i] === 'string') marks[fav[i]] = { on: true, at: MIGRATION_AT_BASE + (fav.length - i) };
            }
            writeJSON(FAV_KEY, marks);
        }
        var sfav = readJSON(SHORTFAV_KEY, null);
        if (Array.isArray(sfav)) {
            var smarks = {};
            for (var j = 0; j < sfav.length; j++) {
                var e = sfav[j];
                // ショートは元から at を持っているのでそれを尊重する
                if (e && e.id) smarks[e.id] = { on: true, t: e.t || 0, at: e.at || MIGRATION_AT_BASE };
            }
            writeJSON(SHORTFAV_KEY, smarks);
        }
        // mms_history / mms_progress は形も at もそのままなので変換不要。
        // 旧 resume_<id> キーは移行しない。タイムスタンプが無く、他端末の本物の進捗と衝突したときに
        // 勝敗を決められないため。resumeSecondsFor の端末ローカルのフォールバックとして残す。
        try { localStorage.setItem(SYNC_KEY_MIGRATED, '1'); } catch (e2) {}
    }

    function isFavorite(id) { return state.favorites.indexOf(id) >= 0; }
    function toggleFavorite(id) {
        var m = state.favMarks[id];
        var on = !(m && m.on);
        // 外した事実を {on:false, at} として残さないと、他端末の古い記録とマージしたときに復活する
        state.favMarks[id] = { on: on, at: Date.now() };
        rebuildFavorites();
        markDirty();
        return on;
    }

    /// 履歴は「最後に開いた順」。同じものは前の記録を消して先頭へ積み直す。
    function recordHistory(id) {
        for (var i = state.history.length - 1; i >= 0; i--) {
            if (state.history[i].id === id) state.history.splice(i, 1);
        }
        state.history.unshift({ id: id, at: Date.now() });
        if (state.history.length > HISTORY_MAX) state.history.length = HISTORY_MAX;
        markDirty();
    }

    /// ショートのお気に入りは「動画＋クリップ開始位置」で覚える（iOS版と同じ考え方）
    function shortsFavIndex(id) {
        for (var i = 0; i < state.shortsFavs.length; i++) if (state.shortsFavs[i].id === id) return i;
        return -1;
    }
    function toggleShortsFav(id, startTime) {
        var m = state.shortsFavMarks[id];
        var on = !(m && m.on);
        // 外したときも t を残す。他端末の古い記録とマージした際にクリップ位置が 0 に潰れないため
        state.shortsFavMarks[id] = { on: on, t: on ? (startTime || 0) : (m ? (m.t || 0) : 0), at: Date.now() };
        rebuildShortsFavs();
        markDirty();
        return on;
    }

    // ======================= 再生の設定 =======================
    var PLAYBACK_KEY = 'mms_playback';
    // 再生の設定は端末に閉じたまま同期しない。音量とミュートはその端末のスピーカー／イヤホンの
    // 都合そのもので、Mac 側を 20% にしたせいで外出先のスマホまで 20% になるのは実害でしかない。
    // 速度・自動再生・リピート・シャッフルも、その場のセッションで気軽に切り替えるものなので、
    // 別端末の操作で再生中に勝手に変わる方が混乱が大きい。
    // 同期するのは「その動画が自分にとって何か（見た位置・お気に入り・履歴）」だけ、
    // 「この端末でどう再生するか」は同期しない、という切り分け。
    // 同じ理由で state.mangaMode / shortsMuted / shortsZoom / state.quality も同期対象外。
    function savePlayback() { writeJSON(PLAYBACK_KEY, state.playback); }

    // ======================= 視聴位置の記録 =======================
    // 旧版は resume_<id> に秒数だけ入れていた。並べ替えに「最後に見た時刻」が要るので
    // 1つの辞書にまとめ直す。古いキーは読み取りだけ引き継ぐ。
    var PROGRESS_KEY = 'mms_progress';
    var PROGRESS_MAX = 300;
    // 保存のデバウンスは markDirty()／scheduleSyncPush() に一本化した。
    // localStorage 用とサーバー送信用で経路が2本あると、片方だけ発火する状態が生まれて切り分けできない。

    function loadProgress() {
        try { return JSON.parse(localStorage.getItem(PROGRESS_KEY) || '{}') || {}; }
        catch (e) { return {}; }
    }

    function resumeSecondsFor(video) {
        var entry = state.progress[video.id];
        // t<=0 は clearProgress が残した「見終わった」の記録。ここで legacy へ落とすと、
        // 消したはずの再開位置が旧 resume_ キーから蘇る。
        if (entry) return entry.t > 0 ? entry.t : 0;
        var legacy = parseFloat(localStorage.getItem('resume_' + video.id) || '0');
        return isFinite(legacy) ? legacy : 0;
    }

    function progressFor(video) {
        if (!(video.duration > 0)) return 0;
        return Math.max(0, Math.min(1, resumeSecondsFor(video) / video.duration));
    }

    function setProgress(id, seconds) {
        state.progress[id] = { t: seconds, at: Date.now() };
        markDirty();
    }

    /// 「見終わった」はエントリの削除ではなくトゥームストーン（t:0）で残す。
    /// 消してしまうと、まだ古い進捗を持っている別端末が「残り数秒」の再開位置を復活させ、
    /// 続きを見るタブにも再登場する。isPartiallyWatched は progressFor 経由で t=0 → 0 と
    /// 評価するので、既存の表示判定はそのまま正しく動く。
    function clearProgress(id) {
        state.progress[id] = { t: 0, at: Date.now() };
        localStorage.removeItem('resume_' + id);
        markDirty();
    }

    /// 見終わった／始めていないものにはバーを出さない
    function isPartiallyWatched(v) {
        var p = progressFor(v);
        return p > 0.02 && p < 0.98;
    }

    function watchedBarHTML(v) {
        if (!isPartiallyWatched(v)) return '';
        return '<div class="watched"><div class="watched-fill" style="width:' +
            (progressFor(v) * 100).toFixed(1) + '%"></div></div>';
    }

    function findVideoByID(id) {
        var pools = [state.homeAll, state.albumRaw, state.shortsPool];
        for (var p = 0; p < pools.length; p++) {
            for (var i = 0; i < pools[p].length; i++) if (pools[p][i].id === id) return pools[p][i];
        }
        return null;
    }

    /// 描画済みカードの重ね物（視聴済みバー・お気に入りのハート）だけ差し替える。
    /// 一覧を作り直すとスクロール位置が飛ぶので、こちらで済ませる。
    function refreshCardOverlays() {
        var nodes = document.querySelectorAll('[data-watch-id]');
        for (var i = 0; i < nodes.length; i++) {
            var id = nodes[i].getAttribute('data-watch-id');

            var heart = nodes[i].querySelector('.fav-badge');
            if (isFavorite(id) && !heart) nodes[i].insertAdjacentHTML('beforeend', FAV_ICON);
            else if (!isFavorite(id) && heart) heart.remove();

            var v = findVideoByID(id);
            if (!v) continue;
            var bar = nodes[i].querySelector('.watched');
            if (!isPartiallyWatched(v)) { if (bar) bar.remove(); continue; }
            if (bar) bar.firstElementChild.style.width = (progressFor(v) * 100).toFixed(1) + '%';
            else nodes[i].insertAdjacentHTML('beforeend', watchedBarHTML(v));
        }
    }

    function shuffle(arr) {
        var a = arr.slice();
        for (var i = a.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1));
            var t = a[i]; a[i] = a[j]; a[j] = t;
        }
        return a;
    }

    function isPhoto(v) { return v.mediaType === 'photo'; }
    function isShortVideo(v) { return !isPhoto(v) && v.duration > 0 && v.duration <= SHORT_MAX_DURATION; }
    function albumNameOf(v) {
        if (!v.parentAlbumID) return 'ライブラリ';
        for (var i = 0; i < state.albums.length; i++) {
            if (state.albums[i].id === v.parentAlbumID) return state.albums[i].name;
        }
        return 'ライブラリ';
    }
    function mediaURL(id, q) { return '/video/' + encodeURIComponent(id) + (q ? '?q=' + q : ''); }
    // 縦横比を保つサムネ（iOS版と同じURLなのでサーバー側のキャッシュを共有できる）
    function thumbURL(id, original) { return '/thumbnail/' + encodeURIComponent(id) + (original ? '?original=true' : ''); }

    function toast(msg) {
        var t = el('toast');
        t.textContent = msg;
        t.classList.add('show');
        clearTimeout(t._timer);
        t._timer = setTimeout(function () { t.classList.remove('show'); }, 2400);
    }

    // サムネ生成が間に合わないとサーバーは 202 で小さな仮画像を返す。少し待って取り直す。
    window.thumbLoaded = function (img) {
        if (img.naturalWidth && img.naturalWidth < 80) {
            var n = (parseInt(img.dataset.retry || '0', 10)) + 1;
            if (n <= 3) {
                img.dataset.retry = String(n);
                var base = img.src.split('&_r=')[0];
                setTimeout(function () { img.src = base + '&_r=' + n; }, 2500 * n);
            }
        }
    };
    window.thumbFailed = function (img) {
        img.style.visibility = 'hidden';
        if (img.parentElement) img.parentElement.classList.add('thumb-fallback');
    };
    function imgTag(url, cls) {
        return '<img class="' + cls + '" src="' + esc(url) + '" loading="lazy" decoding="async" onload="thumbLoaded(this)" onerror="thumbFailed(this)">';
    }

    // ======================= 通信 =======================
    function AuthError() {}

    function api(path, opts) {
        return fetch(path, opts || {}).then(function (res) {
            if (res.status === 401) { showLogin(true); throw new AuthError(); }
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return res;
        });
    }

    function showLogin(wrongPin) {
        el('login-modal').classList.add('open');
        el('login-error').textContent = (wrongPin && document.cookie.indexOf('pin=') >= 0) ? 'PINが正しくありません。' : '';
        setTimeout(function () { el('pin-input').focus(); }, 120);
    }
    function submitPIN() {
        var val = el('pin-input').value.trim();
        if (!val) return;
        // Cookie に入れておくと <img> / <video> のリクエストにも自動で付く
        document.cookie = 'pin=' + encodeURIComponent(val) + ';path=/;max-age=31536000;samesite=lax';
        el('login-modal').classList.remove('open');
        boot(true);
    }

    function loadAlbums(force) {
        if (!force && state.albums.length) return Promise.resolve(state.albums);
        return api('/albums').then(function (r) { return r.json(); }).then(function (albums) {
            state.albums = albums;
            renderNavFoot();
            return albums;
        });
    }

    // ALL VIDEOS の中身＝ホーム／ショートの母集団。短時間キャッシュして往復を減らす。
    function loadAllVideos(force) {
        if (!force && state.allVideos.length && (Date.now() - state.allVideosAt) < ALL_MEDIA_TTL) {
            return Promise.resolve(state.allVideos);
        }
        return loadAlbums(force).then(function (albums) {
            var all = null;
            for (var i = 0; i < albums.length; i++) if (albums[i].name === 'ALL VIDEOS') all = albums[i];
            if (!all) return [];
            return api('/albums/' + encodeURIComponent(all.id) + '/videos').then(function (r) { return r.json(); });
        }).then(function (list) {
            var vids = (list || []).filter(function (v) { return !isPhoto(v); });
            if (vids.length) { state.allVideos = vids; state.allVideosAt = Date.now(); }
            return vids;
        });
    }

    /// ALL PHOTOS の中身。お気に入り・履歴に写真が混じるため別に持つ。
    function loadAllPhotos(force) {
        if (!force && state.allPhotos.length && (Date.now() - state.allPhotosAt) < ALL_MEDIA_TTL) {
            return Promise.resolve(state.allPhotos);
        }
        return loadAlbums(force).then(function (albums) {
            var ap = null;
            for (var i = 0; i < albums.length; i++) if (albums[i].name === 'ALL PHOTOS') ap = albums[i];
            if (!ap) return [];
            return api('/albums/' + encodeURIComponent(ap.id) + '/videos').then(function (r) { return r.json(); });
        }).then(function (list) {
            var photos = list || [];
            if (photos.length) { state.allPhotos = photos; state.allPhotosAt = Date.now(); }
            return photos;
        });
    }

    function loadTrash(force) {
        if (!force && state.trashAt && (Date.now() - state.trashAt) < ALL_MEDIA_TTL) {
            return Promise.resolve(state.trash);
        }
        return api('/trash').then(function (r) { return r.json(); }).then(function (items) {
            state.trash = items || [];
            state.trashAt = Date.now();
            return state.trash;
        });
    }

    function renderNavFoot() {
        var vids = 0, photos = 0;
        for (var i = 0; i < state.albums.length; i++) {
            if (state.albums[i].name === 'ALL VIDEOS') vids = state.albums[i].videoCount;
            if (state.albums[i].name === 'ALL PHOTOS') photos = state.albums[i].videoCount;
        }
        el('nav-foot').innerHTML = '動画 ' + vids + ' 本<br>写真 ' + photos + ' 枚<br>アルバム ' + state.albums.length + ' 個';
    }

    // ======================= タブ / 履歴 =======================
    // keepAlbum: 履歴でアルバム詳細へ戻るときだけ true（詳細を閉じずに開き直す）
    function showTab(tab, push, keepAlbum) {
        state.tab = tab;
        var panels = ['home', 'continue', 'shorts', 'albums'];
        for (var i = 0; i < panels.length; i++) {
            el('panel-' + panels[i]).classList.toggle('active', panels[i] === tab);
        }
        var items = document.querySelectorAll('.nav-item');
        for (var j = 0; j < items.length; j++) {
            var isCurrent = items[j].dataset.tab === tab;
            items[j].classList.toggle('active', isCurrent);
            if (isCurrent) items[j].setAttribute('aria-current', 'page');
            else items[j].removeAttribute('aria-current');
        }
        document.body.classList.toggle('shorts-mode', tab === 'shorts');
        el('search-wrap').classList.toggle('hidden', tab === 'shorts');
        window.scrollTo(0, 0);

        if (tab !== 'shorts') pauseShorts();
        if (push !== false) history.pushState({ view: 'tab', tab: tab }, '', '#' + tab);

        if (tab === 'home') ensureHome();
        if (tab === 'continue') ensureContinue();
        if (tab === 'albums') ensureAlbums(keepAlbum);
        if (tab === 'shorts') ensureShorts();
    }

    function applyLocation(push) {
        var h = (location.hash || '').replace(/^#/, '');
        if (h.indexOf('album/') === 0) { showTab('albums', false, true); openAlbum(h.slice(6), false); return; }
        if (h.indexOf('watch/') === 0) {
            // 共有された動画リンク。履歴の起点をホームに直してから重ねるので、
            // 「戻る」でサイトの外に出ずホームへ帰れる。
            var wantID = h.slice(6);
            history.replaceState({ view: 'tab', tab: 'home' }, '', '#home');
            showTab('home', false);
            openDeepLink(wantID);
            return;
        }
        if (h === 'shorts' || h === 'albums' || h === 'home' || h === 'continue') { showTab(h, push); return; }
        showTab('home', push);
    }

    function indexOfID(list, id) {
        for (var i = 0; i < list.length; i++) if (list[i].id === id) return i;
        return -1;
    }

    /// #watch/<id> で開かれたメディアを探して再生する。
    /// 動画はホームの並びから、写真はホームに含まれないので ALL PHOTOS から探す。
    function openDeepLink(id) {
        ensureHome().then(function () {
            var idx = indexOfID(state.homeFiltered, id);
            if (idx >= 0) { openMedia('home', idx, true); return; }

            var photoAlbum = null;
            for (var i = 0; i < state.albums.length; i++) {
                if (state.albums[i].name === 'ALL PHOTOS') photoAlbum = state.albums[i];
            }
            if (!photoAlbum) { toast('このメディアは見つかりませんでした'); return; }
            showTab('albums', false, true);
            return openAlbum(photoAlbum.id, false).then(function () {
                var j = indexOfID(state.albumFiltered, id);
                if (j >= 0) openMedia('album', j, true);
                else toast('このメディアは見つかりませんでした');
            });
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('このメディアは見つかりませんでした');
        });
    }

    window.addEventListener('popstate', function (e) {
        var st = e.state;
        if (el('player-modal').classList.contains('open') && (!st || st.view !== 'player')) {
            closePlayer(false);
            if (!st) return;
        }
        if (!st) { applyLocation(false); return; }
        if (st.view === 'tab') { showTab(st.tab, false); return; }
        if (st.view === 'album') { showTab('albums', false, true); openAlbum(st.id, false); return; }
        if (st.view === 'player') { showTab(st.tab || 'home', false, true); openMedia(st.origin, st.index, false); return; }
        applyLocation(false);
    });

    // ======================= ホームフィード =======================
    // 直リンク（#watch/<id>）から待ち合わせるため、読み込み中の Promise を使い回す
    var homeLoadPromise = null;
    function ensureHome() {
        if (state.homeAll.length) return Promise.resolve();
        if (homeLoadPromise) return homeLoadPromise;
        el('home-state').classList.remove('hidden');
        homeLoadPromise = loadAllVideos(false).then(function (vids) {
            state.homeAll = shuffle(vids);
            applyHomeFilter();
        }).catch(function (e) {
            if (!(e instanceof AuthError)) el('home-state').innerHTML = '<div>読み込みに失敗しました</div>';
        }).then(function () {
            homeLoadPromise = null;
        });
        return homeLoadPromise;
    }

    function applyHomeFilter() {
        var q = el('global-search').value.trim().toLowerCase();
        state.homeFiltered = q
            ? state.homeAll.filter(function (v) { return v.filename.toLowerCase().indexOf(q) >= 0; })
            : state.homeAll.slice();
        state.homeRendered = 0;
        el('home-feed').innerHTML = '';
        if (!state.homeFiltered.length) {
            el('home-state').classList.remove('hidden');
            el('home-state').innerHTML = '<div>' + (q ? '一致する動画がありません' : '動画がありません') + '</div>';
            return;
        }
        el('home-state').classList.add('hidden');
        // ショートの山札は読み込み（と検索・更新）のたびに切り直す。
        // 描画中は固定なので、スクロールで棚が作り直されても中身は動かない。
        state.shortsDeck = shuffle(state.homeFiltered.filter(isShortVideo));
        rerenderHomeFeed();
    }

    // ======================= 続きを見る（タブ） =======================
    /// 途中まで見た動画だけを、最後に見た順に並べる。
    /// このタブ専用の再生リストを作るので、開いた動画の「次の動画」も続きを見るの並びになる。
    function ensureContinue() {
        el('continue-state').innerHTML = '<div class="spinner"></div><div>読み込み中...</div>';
        el('continue-state').classList.remove('hidden');
        return loadAllVideos(false).then(function () {
            renderContinue();
        }).catch(function (e) {
            if (e instanceof AuthError) return;
            el('continue-state').innerHTML = '<div>読み込みに失敗しました</div>';
        });
    }

    function renderContinue() {
        var q = el('global-search').value.trim().toLowerCase();
        var items = [];
        for (var i = 0; i < state.allVideos.length; i++) {
            var v = state.allVideos[i];
            if (!isPartiallyWatched(v)) continue;
            if (q && v.filename.toLowerCase().indexOf(q) < 0) continue;
            var entry = state.progress[v.id];
            items.push({ v: v, at: entry ? (entry.at || 0) : 0 });
        }
        items.sort(function (a, b) { return b.at - a.at; });
        state.continueList = items.map(function (x) { return x.v; });

        var host = el('continue-feed');
        if (!state.continueList.length) {
            host.innerHTML = '';
            el('continue-state').classList.remove('hidden');
            el('continue-state').innerHTML = q
                ? '<div>一致する動画がありません</div>'
                : '<div class="crow-empty"><div class="big">途中まで見た動画はありません</div>' +
                  '<div>再生の途中でやめた動画が、ここに並びます。</div></div>';
            return;
        }
        el('continue-state').classList.add('hidden');

        var html = '';
        for (var j = 0; j < state.continueList.length; j++) {
            var vid = state.continueList[j];
            var left = Math.max(0, vid.duration - resumeSecondsFor(vid));
            html += '<div class="feed-card" role="button" tabindex="0" data-action="play-continue" data-index="' + j + '">' +
                '<div class="feed-thumb" data-id="' + esc(vid.id) + '" data-watch-id="' + esc(vid.id) + '">' +
                    imgTag(thumbURL(vid.id, true), '') +
                    '<div class="badge-dur chip-on-media">残り ' + formatDur(left) + '</div>' +
                    (isFavorite(vid.id) ? FAV_ICON : '') + watchedBarHTML(vid) + '</div>' +
                '<div class="feed-meta">' +
                    '<div class="avatar"><svg class="ico-s" viewBox="0 0 24 24"><path d="M10 8.6 15.5 12 10 15.4zM21 6.5c-.2-1.7-.9-2.9-2.7-3.1C16.4 3.1 13.9 3 12 3s-4.4.1-6.3.4C3.9 3.6 3.2 4.8 3 6.5 2.9 7.7 2.8 9.3 2.8 12s.1 4.3.2 5.5c.2 1.7.9 2.9 2.7 3.1 1.9.3 4.4.4 6.3.4s4.4-.1 6.3-.4c1.8-.2 2.5-1.4 2.7-3.1.1-1.2.2-2.8.2-5.5s-.1-4.3-.2-5.5"/></svg></div>' +
                    '<div class="feed-text">' +
                        '<div class="feed-title" title="' + esc(vid.filename) + '">' + esc(cleanTitle(vid.filename)) + '</div>' +
                        '<div class="feed-sub">' + esc(albumNameOf(vid)) + ' • ' + esc(timeAgo(vid.importDate)) + '</div>' +
                        '<div class="cw-left">' + Math.round(progressFor(vid) * 100) + '% 視聴済み</div>' +
                    '</div>' +
                '</div></div>';
        }
        host.innerHTML = html;
    }

    function rerenderHomeFeed() {
        state.homeRendered = 0;
        state.shelfOrdinal = 0;
        state.feedCols = feedColumns();
        state.shelfPlan = buildShelfPlan(state.homeFiltered.length, state.feedCols);
        el('home-feed').innerHTML = '';
        renderHomeChunk();
    }

    /// フィードが何列で並んでいるか。棚の間隔をこれで決める。
    function feedColumns() {
        if (!isDesktop()) return 1;
        var feed = el('home-feed');
        var tracks = getComputedStyle(feed).gridTemplateColumns.split(' ').filter(function (s) {
            return s && s !== 'none';
        }).length;
        if (tracks > 0) return tracks;
        return Math.max(1, Math.floor((feed.clientWidth || 0) / 326));
    }

    /// 棚を挟む位置をあらかじめ決める。
    /// Mac は1行に何本も並ぶので「何本おき」で数えると棚だらけになる。行数で数える。
    function buildShelfPlan(total, cols) {
        var plan = {};
        if (total < 2) return plan;
        var at = cols > 1 ? cols * 2 - 1 : 1;   // Mac は横動画を2行見せてから最初の棚
        var seed = 12345;
        while (at < total) {
            plan[at] = true;
            seed = (Math.imul(seed, 1103515245) + 12345) | 0;
            at += cols > 1
                ? cols * (2 + (Math.abs(seed) % 3))   // Mac: 2〜4行おき
                : 4 + (Math.abs(seed) % 7);           // スマホ: 4〜10本おき（iOS版と同じ）
        }
        return plan;
    }

    /// 棚ごとに山札の違う区間を配る。
    /// 棚ごとに無作為抽出すると偶然かぶるので、順に切り出して重複を避ける。
    function shelfVideos(ordinal) {
        var deck = state.shortsDeck;
        if (!deck.length) return [];
        var per = Math.min(SHELF_SIZE, deck.length);
        // 山札が棚1枚に満たないときは全部出すしかないので、開始位置だけずらして並びを変える
        var stride = deck.length > per ? per : Math.max(1, Math.floor(deck.length / 3));
        var start = (ordinal * stride) % deck.length;
        var out = [];
        for (var i = 0; i < per; i++) out.push(deck[(start + i) % deck.length]);
        return out;
    }

    function feedCardHTML(v, index) {
        var dur = !isPhoto(v) && v.duration > 0 ? '<div class="badge-dur chip-on-media">' + formatDur(v.duration) + '</div>' : '';
        return '<div class="feed-card" role="button" tabindex="0" data-action="play-home" data-index="' + index + '">' +
            '<div class="feed-thumb" data-id="' + esc(v.id) + '" data-watch-id="' + esc(v.id) + '">' +
                imgTag(thumbURL(v.id, true), '') + dur +
                (isFavorite(v.id) ? FAV_ICON : '') + watchedBarHTML(v) + '</div>' +
            '<div class="feed-meta">' +
                '<div class="avatar"><svg class="ico-s" viewBox="0 0 24 24"><path d="M10 8.6 15.5 12 10 15.4zM21 6.5c-.2-1.7-.9-2.9-2.7-3.1C16.4 3.1 13.9 3 12 3s-4.4.1-6.3.4C3.9 3.6 3.2 4.8 3 6.5 2.9 7.7 2.8 9.3 2.8 12s.1 4.3.2 5.5c.2 1.7.9 2.9 2.7 3.1 1.9.3 4.4.4 6.3.4s4.4-.1 6.3-.4c1.8-.2 2.5-1.4 2.7-3.1.1-1.2.2-2.8.2-5.5s-.1-4.3-.2-5.5"/></svg></div>' +
                '<div class="feed-text">' +
                    '<div class="feed-title" title="' + esc(v.filename) + '">' + esc(cleanTitle(v.filename)) + '</div>' +
                    '<div class="feed-sub">' + esc(albumNameOf(v)) + ' • ' + esc(timeAgo(v.importDate)) + '</div>' +
                '</div>' +
            '</div></div>';
    }

    function shelfHTML(ordinal) {
        var items = shelfVideos(ordinal);
        if (!items.length) return '';
        var cards = '';
        for (var i = 0; i < items.length; i++) {
            var v = items[i];
            cards += '<div class="short-card" role="button" tabindex="0" data-action="play-short" data-id="' + esc(v.id) + '">' +
                '<div class="short-thumb">' + imgTag(thumbURL(v.id, true), '') +
                    '<div class="badge-dur chip-on-media">' + formatDur(v.duration) + '</div></div>' +
                '<div class="short-title">' + esc(cleanTitle(v.filename)) + '</div></div>';
        }
        return '<div class="shelf">' +
            '<div class="shelf-head"><span class="ico"><svg class="ico" viewBox="0 0 24 24" fill="currentColor"><path d="M13.4 2.1c.5 2.7-.7 4.1-2.1 5.6-1.6 1.7-3.5 3.3-3.5 6.2a6.2 6.2 0 0 0 12.4 0c0-2.2-1-4.2-2.5-5.8.1 1.7-.5 3-1.7 3.7.8-3.8-1.1-7.4-2.6-9.7"/></svg></span>おすすめショート</div>' +
            '<div class="shelf-row">' + cards + '</div></div>';
    }

    function renderHomeChunk() {
        var list = state.homeFiltered;
        if (state.homeRendered >= list.length) return;
        var end = Math.min(state.homeRendered + FEED_CHUNK, list.length);
        var hasShorts = state.shortsDeck.length > 0;
        var html = '';
        for (var i = state.homeRendered; i < end; i++) {
            html += feedCardHTML(list[i], i);
            if (hasShorts && state.shelfPlan[i]) {
                html += shelfHTML(state.shelfOrdinal);
                state.shelfOrdinal++;
            }
        }
        // 動画が少なく棚を挟む位置が取れなかったときは、最後に1枚だけ付ける
        if (end === list.length && hasShorts && state.shelfOrdinal === 0) {
            html += shelfHTML(0);
            state.shelfOrdinal++;
        }
        el('home-feed').insertAdjacentHTML('beforeend', html);
        state.homeRendered = end;
    }

    var feedObserver = new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting && state.tab === 'home') renderHomeChunk();
    }, { rootMargin: '900px' });

    // --- Mac だけ: サムネにカーソルを乗せるとミュートで先読み再生（YouTube のプレビューと同じ） ---
    var preview = { timer: null, node: null };
    function clearPreview() {
        clearTimeout(preview.timer);
        if (preview.node) {
            preview.node.pause();
            preview.node.removeAttribute('src');
            preview.node.load();
            preview.node.remove();
            preview.node = null;
        }
    }
    function attachPreview(thumb) {
        if (!canHover || !isDesktop()) return;
        clearPreview();
        preview.timer = setTimeout(function () {
            if (!document.body.contains(thumb)) return;
            var v = document.createElement('video');
            v.muted = true; v.playsInline = true; v.preload = 'auto'; v.loop = true;
            v.src = mediaURL(thumb.dataset.id);
            v.addEventListener('loadedmetadata', function () {
                if (v.duration && isFinite(v.duration) && v.duration > 20) v.currentTime = v.duration * 0.1;
            });
            v.play().catch(function () {});
            thumb.appendChild(v);
            preview.node = v;
        }, 700);
    }

    // ======================= アルバム =======================
    function ensureAlbums(keepAlbum) {
        // アルバムタブに戻ってきたのに詳細が開いたまま、を防ぐ
        if (!keepAlbum && state.currentAlbum) closeAlbum();
        if (el('albums-list').dataset.loaded === '1') { refreshVirtualCounts(); filterAlbums(); return; }
        el('albums-list').innerHTML = '<div class="state-box"><div class="spinner"></div><div>読み込み中...</div></div>';
        loadAlbums(false).then(renderAlbums).catch(function (e) {
            if (e instanceof AuthError) return;
            el('albums-list').innerHTML = '<div class="state-box">読み込みに失敗しました</div>';
        });
    }

    // ブラウザ側だけで組み立てる「仮想アルバム」。サーバーは関与しない（iOS版と同じ考え方）。
    var VIRTUAL_ALBUMS = [
        { id: 'HISTORY', name: '再生履歴', type: 'video',
          icon: '<path d="M12 3a9 9 0 1 0 9 9h-2a7 7 0 1 1-7-7zm1 4h-2v6l5 3 1-1.7-4-2.3z"/>' },
        { id: 'FAVORITES', name: 'お気に入り', type: 'video',
          icon: '<path d="M12 21S3.5 14.6 3.5 9.2A4.7 4.7 0 0 1 12 6.3a4.7 4.7 0 0 1 8.5 2.9C20.5 14.6 12 21 12 21"/>' },
        { id: 'SHORTS_FAVORITES', name: 'ショートのお気に入り', type: 'video',
          icon: '<path d="M13.4 2.1c.5 2.7-.7 4.1-2.1 5.6-1.6 1.7-3.5 3.3-3.5 6.2a6.2 6.2 0 0 0 12.4 0c0-2.2-1-4.2-2.5-5.8.1 1.7-.5 3-1.7 3.7.8-3.8-1.1-7.4-2.6-9.7"/>' },
        { id: 'TRASH', name: 'ゴミ箱', type: 'mixed',
          icon: '<path d="M7 21a2 2 0 0 1-2-2V7h14v12a2 2 0 0 1-2 2zm1-3h2V10H8zm6 0h2V10h-2zM4 4h5l1-1h4l1 1h5v2H4z"/>' }
    ];
    function isVirtualAlbumID(id) {
        for (var i = 0; i < VIRTUAL_ALBUMS.length; i++) if (VIRTUAL_ALBUMS[i].id === id) return true;
        return false;
    }
    function virtualAlbumCount(id) {
        if (id === 'HISTORY') return state.history.length;
        if (id === 'FAVORITES') return state.favorites.length;
        if (id === 'SHORTS_FAVORITES') return state.shortsFavs.length;
        return state.trash.length;
    }
    /// 一覧のHTMLは使い回すので、お気に入り・履歴が増えても件数だけは貼り替える
    function refreshVirtualCounts() {
        for (var i = 0; i < VIRTUAL_ALBUMS.length; i++) {
            var badge = el('albums-list').querySelector('.album-card[data-id="' + VIRTUAL_ALBUMS[i].id + '"] .album-count');
            if (badge) badge.textContent = virtualAlbumCount(VIRTUAL_ALBUMS[i].id);
        }
    }

    function virtualAlbumCards() {
        var html = '';
        for (var i = 0; i < VIRTUAL_ALBUMS.length; i++) {
            var a = VIRTUAL_ALBUMS[i];
            html += '<div class="album-card" role="button" tabindex="0" data-action="open-album" data-id="' + a.id +
                    '" data-name="' + esc(a.name.toLowerCase()) + '">' +
                '<div class="album-thumb"><div class="album-empty">' +
                    '<svg viewBox="0 0 24 24" fill="currentColor">' + a.icon + '</svg></div>' +
                    '<div class="album-count chip-on-media">' + virtualAlbumCount(a.id) + '</div></div>' +
                '<div class="album-name">' + esc(a.name) + '</div></div>';
        }
        return html;
    }

    /// 仮想アルバムの中身を、ローカルの記録と全件リストから組み立てる
    function virtualAlbumContents(id) {
        if (id === 'TRASH') return loadTrash(true);
        // 写真もお気に入り・履歴に入りうるので、動画と写真の両方から引く
        return Promise.all([loadAllVideos(false), loadAllPhotos(false)]).then(function (pair) {
            var pool = pair[0].concat(pair[1]);
            var byID = {};
            for (var i = 0; i < pool.length; i++) byID[pool[i].id] = pool[i];
            var out = [], j;
            if (id === 'HISTORY') {
                for (j = 0; j < state.history.length; j++) {
                    if (byID[state.history[j].id]) out.push(byID[state.history[j].id]);
                }
            } else if (id === 'FAVORITES') {
                for (j = 0; j < state.favorites.length; j++) {
                    if (byID[state.favorites[j]]) out.push(byID[state.favorites[j]]);
                }
            } else {
                for (j = 0; j < state.shortsFavs.length; j++) {
                    if (byID[state.shortsFavs[j].id]) out.push(byID[state.shortsFavs[j].id]);
                }
            }
            return out;
        });
    }

    function renderAlbums() {
        var lib = '', vid = '', pho = '', hasVid = false, hasPho = false;
        for (var i = 0; i < state.albums.length; i++) {
            var a = state.albums[i];
            var inner = a.coverVideoID
                ? imgTag(thumbURL(a.coverVideoID, false), '')
                : '<div class="album-empty"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8z"/></svg></div>';
            var card = '<div class="album-card" role="button" tabindex="0" data-action="open-album" data-id="' + esc(a.id) + '" data-name="' + esc(a.name.toLowerCase()) + '">' +
                '<div class="album-thumb">' + inner + '<div class="album-count chip-on-media">' + a.videoCount + '</div></div>' +
                '<div class="album-name' + (a.type === 'photo' ? ' photo' : '') + '">' + esc(a.name) + '</div></div>';
            if (a.name === 'ALL VIDEOS' || a.name === 'ALL PHOTOS' || a.type === 'mixed') lib += card;
            else if (a.type === 'photo') { pho += card; hasPho = true; }
            else { vid += card; hasVid = true; }
        }
        var html = '<div class="toolbar"><button class="pill btn-accent" id="new-album-btn">＋ 新規アルバム</button></div>';
        html += '<div class="section-title">マイライブラリ</div><div class="album-grid">' + virtualAlbumCards() + '</div>';
        html += '<div class="section-title">ライブラリ</div><div class="album-grid">' + lib + '</div>';
        if (hasVid) html += '<div class="section-title">動画アルバム</div><div class="album-grid">' + vid + '</div>';
        if (hasPho) html += '<div class="section-title">写真アルバム</div><div class="album-grid">' + pho + '</div>';
        el('albums-list').innerHTML = html;
        el('albums-list').dataset.loaded = '1';
        el('new-album-btn').addEventListener('click', openCreateAlbum);
        loadTrash(false).then(refreshVirtualCounts).catch(function () {});
        filterAlbums();
    }

    // ======================= アルバムの作成 =======================
    function openCreateAlbum() {
        el('create-name').value = '';
        el('create-error').textContent = '';
        el('create-modal').classList.add('open');
        setTimeout(function () { el('create-name').focus(); }, 100);
    }

    function submitCreateAlbum() {
        var name = el('create-name').value.trim();
        if (!name) { el('create-error').textContent = '名前を入力してください。'; return; }
        // サーバーは ALL VIDEOS / ALL PHOTOS と同名を弾いて何も作らないので、手前で伝える
        if (name === 'ALL VIDEOS' || name === 'ALL PHOTOS') {
            el('create-error').textContent = 'この名前は使えません。';
            return;
        }
        for (var i = 0; i < state.albums.length; i++) {
            if (state.albums[i].name === name) { el('create-error').textContent = '同じ名前のアルバムがあります。'; return; }
        }
        el('create-ok').disabled = true;
        api('/albums/create', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: name, type: el('create-type').value })
        }).then(function () {
            el('create-modal').classList.remove('open');
            toast('「' + name + '」を作成しました');
            return reloadAlbumList();
        }).catch(function (e) {
            if (!(e instanceof AuthError)) el('create-error').textContent = '作成に失敗しました。';
        }).then(function () { el('create-ok').disabled = false; });
    }

    /// アルバム一覧を作り直す（作成・アップロード後に件数を合わせるため）
    function reloadAlbumList() {
        el('albums-list').dataset.loaded = '';
        return loadAlbums(true).then(renderAlbums).catch(function () {});
    }

    // ======================= アルバムの選択シート =======================
    var pickerChoice = null;

    /// 移動先などを選ばせる。onPick には選ばれたアルバムを渡す。
    function openAlbumPicker(title, excludeID, onPick, customOnly) {
        var html = '';
        for (var i = 0; i < state.albums.length; i++) {
            var a = state.albums[i];
            if (a.id === excludeID) continue;
            if (customOnly && isSystemAlbum(a)) continue;
            html += '<button class="sheet-item" data-pick="' + esc(a.id) + '">' +
                esc(a.name) + '<span class="count">' + a.videoCount + '</span></button>';
        }
        if (!html) html = '<div style="color:var(--text-2); font-size:13px">選べるアルバムがありません。</div>';
        el('picker-title').textContent = title;
        el('picker-list').innerHTML = html;
        pickerChoice = onPick;
        el('picker-modal').classList.add('open');
    }

    function closeAlbumPicker() {
        el('picker-modal').classList.remove('open');
        pickerChoice = null;
    }

    function isSystemAlbum(album) {
        return !!album && (album.name === 'ALL VIDEOS' || album.name === 'ALL PHOTOS');
    }

    function renameCurrentAlbum() {
        var album = state.currentAlbum;
        if (!album || isVirtualAlbumID(album.id) || isSystemAlbum(album)) return;
        var value = prompt('新しいアルバム名を入力してください。', album.name);
        if (value === null) return;
        value = value.trim();
        if (!value || value.length > 80 || value === 'ALL VIDEOS' || value === 'ALL PHOTOS') {
            toast('そのアルバム名は使えません');
            return;
        }
        api('/albums/' + encodeURIComponent(album.id) + '/rename', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: value })
        }).then(function () {
            album.name = value;
            el('detail-title').textContent = value;
            toast('アルバム名を変更しました');
            return reloadAlbumList();
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('同名のアルバムがあるか，名前を変更できませんでした');
        });
    }

    function deleteCurrentAlbum() {
        var album = state.currentAlbum;
        if (!album || isVirtualAlbumID(album.id) || isSystemAlbum(album)) return;
        var choice = prompt(
            '「' + album.name + '」の削除方法を番号で選んでください。\n' +
            '1: アルバムだけ削除（中身を残す）\n' +
            '2: 中身をアプリ内のゴミ箱へ\n' +
            '3: 中身ごと完全に削除\n' +
            '4: 中身の実ファイルをMacのゴミ箱へ移動',
            '1'
        );
        if (choice === null) return;
        var disposalByChoice = { '1': 'keep', '2': 'appTrash', '3': 'complete', '4': 'systemTrash' };
        var disposal = disposalByChoice[choice.trim()];
        if (!disposal) { toast('1〜4の番号を入力してください'); return; }
        if (disposal === 'complete' && !confirm('中身を完全に削除します。アプリ管理内のファイルは元に戻せません。よろしいですか？')) return;
        if (disposal === 'systemTrash' && !confirm('リンク元を含む実ファイルをMacのゴミ箱へ移動します。よろしいですか？')) return;
        api('/albums/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ albumIds: [album.id], contentDisposal: disposal })
        }).then(function (response) { return response.json(); }).then(function (result) {
            if (!result.deletedAlbumIDs || result.deletedAlbumIDs.indexOf(album.id) < 0) {
                var failures = result.systemTrashResult && result.systemTrashResult.failures;
                toast(failures && failures.length ? failures.length + ' 件を移動できなかったためアルバムを残しました' : 'アルバムを削除できませんでした');
                return;
            }
            closeAlbum();
            history.replaceState({ view: 'tab', tab: 'albums' }, '', '#albums');
            toast('アルバムを削除しました');
            return reloadAlbumList();
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('アルバムを削除できませんでした');
        });
    }

    function filterAlbums() {
        if (state.currentAlbum) return;
        var q = el('global-search').value.trim().toLowerCase();
        var cards = el('albums-list').querySelectorAll('.album-card');
        for (var i = 0; i < cards.length; i++) {
            cards[i].classList.toggle('hidden', !!q && cards[i].dataset.name.indexOf(q) < 0);
        }
    }

    function openAlbum(albumId, push) {
        var album = null;
        for (var i = 0; i < state.albums.length; i++) if (state.albums[i].id === albumId) album = state.albums[i];
        if (!album && isVirtualAlbumID(albumId)) {
            for (var k = 0; k < VIRTUAL_ALBUMS.length; k++) {
                if (VIRTUAL_ALBUMS[k].id === albumId) album = VIRTUAL_ALBUMS[k];
            }
        }
        var go = album ? Promise.resolve(album) : loadAlbums(true).then(function (list) {
            for (var j = 0; j < list.length; j++) if (list[j].id === albumId) return list[j];
            return null;
        });

        return go.then(function (a) {
            if (!a) { toast('アルバムが見つかりません'); return; }
            state.currentAlbum = a;
            el('albums-list').classList.add('hidden');
            el('album-detail').classList.remove('hidden');
            el('detail-title').textContent = a.name;
            el('media-grid').className = 'media-grid ' + (a.type === 'photo' ? 'ratio-square' : 'ratio-video');
            el('media-grid').innerHTML = '<div class="state-box" style="grid-column:1/-1"><div class="spinner"></div><div>読み込み中...</div></div>';
            el('detail-count').textContent = '';
            exitSelectMode();
            var virtualAlbum = isVirtualAlbumID(a.id);
            var trashAlbum = a.id === 'TRASH';
            // ゴミ箱だけは復元・完全削除のため選択できます。その他の仮想アルバムは読み取り専用です。
            el('select-btn').classList.toggle('hidden', virtualAlbum && !trashAlbum);
            el('upload-btn').classList.toggle('hidden', virtualAlbum);
            el('rename-album-btn').classList.toggle('hidden', virtualAlbum || isSystemAlbum(a));
            el('delete-album-btn').classList.toggle('hidden', virtualAlbum || isSystemAlbum(a));
            el('empty-trash-btn').classList.toggle('hidden', !trashAlbum);
            el('empty-trash-system-btn').classList.toggle('hidden', !trashAlbum);
            el('album-shorts-btn').classList.toggle('hidden', trashAlbum);
            el('bulk-restore').classList.toggle('hidden', !trashAlbum);
            el('bulk-trash').classList.toggle('hidden', trashAlbum);
            el('bulk-move').classList.toggle('hidden', trashAlbum);
            el('bulk-fav').classList.toggle('hidden', trashAlbum);
            if (push !== false) history.pushState({ view: 'album', id: a.id }, '', '#album/' + a.id);
            if (isVirtualAlbumID(a.id)) return virtualAlbumContents(a.id);
            return api('/albums/' + encodeURIComponent(a.id) + '/videos').then(function (r) { return r.json(); });
        }).then(function (list) {
            if (!list) return;
            state.albumRaw = list;
            renderAlbumGrid();
        }).catch(function (e) {
            if (e instanceof AuthError) return;
            el('media-grid').innerHTML = '<div class="state-box" style="grid-column:1/-1">取得に失敗しました</div>';
        });
    }

    function closeAlbum() {
        state.currentAlbum = null;
        state.albumRaw = [];
        state.albumFiltered = [];
        el('album-detail').classList.add('hidden');
        el('albums-list').classList.remove('hidden');
        filterAlbums();
    }

    var ALBUM_CHUNK = 24;
    var FAV_ICON = '<div class="fav-badge"><svg viewBox="0 0 24 24"><path d="M12 21S3.5 14.6 3.5 9.2A4.7 4.7 0 0 1 12 6.3a4.7 4.7 0 0 1 8.5 2.9C20.5 14.6 12 21 12 21"/></svg></div>';
    var CHECK_ICON = '<div class="sel-check"><svg viewBox="0 0 24 24"><path d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/></svg></div>';

    function timeValue(iso) { var t = new Date(iso).getTime(); return isFinite(t) ? t : 0; }

    function renderAlbumGrid() {
        var q = el('global-search').value.trim().toLowerCase();
        var order = el('sort-select').value;
        var list = state.albumRaw.filter(function (v) { return !q || v.filename.toLowerCase().indexOf(q) >= 0; });
        var shot = function (v) { return timeValue(v.creationDate || v.importDate); };
        // 履歴とお気に入りは「記録した順」そのものが意味を持つので並べ替えない
        if (!isVirtualAlbumID(state.currentAlbum ? state.currentAlbum.id : '')) {
            list.sort(function (a, b) {
                switch (order) {
                    case 'importAsc': return timeValue(a.importDate) - timeValue(b.importDate);
                    case 'creationDesc': return shot(b) - shot(a);
                    case 'creationAsc': return shot(a) - shot(b);
                    case 'durationDesc': return (b.duration || 0) - (a.duration || 0);
                    case 'durationAsc': return (a.duration || 0) - (b.duration || 0);
                    case 'nameAsc': return a.filename.localeCompare(b.filename, 'ja');
                    case 'sizeDesc': return (b.fileSize || 0) - (a.fileSize || 0);
                    case 'sizeAsc': return (a.fileSize || 0) - (b.fileSize || 0);
                    case 'modifiedDesc': return timeValue(b.modificationDate) - timeValue(a.modificationDate);
                    case 'modifiedAsc': return timeValue(a.modificationDate) - timeValue(b.modificationDate);
                    case 'lastOpenedDesc': return timeValue(b.accessDate) - timeValue(a.accessDate);
                    default: return timeValue(b.importDate) - timeValue(a.importDate);
                }
            });
        }
        state.albumFiltered = list;
        el('detail-count').textContent = list.length + ' 件';
        el('sort-select').classList.toggle('hidden', isVirtualAlbumID(state.currentAlbum ? state.currentAlbum.id : ''));

        state.albumRendered = 0;
        el('media-grid').innerHTML = '';
        if (!list.length) {
            el('media-grid').innerHTML = '<div class="state-box" style="grid-column:1/-1">メディアがありません</div>';
            return;
        }
        renderAlbumChunk();
    }

    /// 数千件のアルバムでも固まらないよう、24件ずつ足していく
    function renderAlbumChunk() {
        var list = state.albumFiltered;
        if (state.albumRendered >= list.length) return;
        var end = Math.min(state.albumRendered + ALBUM_CHUNK, list.length);
        var html = '';
        for (var i = state.albumRendered; i < end; i++) {
            var v = list[i];
            var photo = isPhoto(v);
            var badge = photo ? '<div class="badge-photo chip-on-media">写真</div>'
                : (v.duration > 0 ? '<div class="badge-dur chip-on-media">' + formatDur(v.duration) + '</div>' : '');
            var sel = state.selected.indexOf(v.id) >= 0;
            html += '<div class="media-card' + (sel ? ' selected' : '') + '" role="button" tabindex="0"' +
                    ' data-action="play-album" data-index="' + i + '" data-id="' + esc(v.id) + '">' +
                '<div class="media-thumb" data-watch-id="' + esc(v.id) + '">' +
                    imgTag(thumbURL(v.id, !photo), '') + badge +
                    (isFavorite(v.id) ? FAV_ICON : '') +
                    (state.selectMode ? CHECK_ICON : '') + watchedBarHTML(v) + '</div>' +
                '<div class="media-name" title="' + esc(v.filename) + '">' + esc(cleanTitle(v.filename)) + '</div></div>';
        }
        el('media-grid').insertAdjacentHTML('beforeend', html);
        state.albumRendered = end;
    }

    var albumObserver = new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting && state.currentAlbum) renderAlbumChunk();
    }, { rootMargin: '800px' });

    // ======================= 複数選択 =======================
    function enterSelectMode() {
        state.selectMode = true;
        state.selected = [];
        el('bulk-bar').classList.remove('hidden');
        el('select-btn').classList.add('on');
        updateBulkBar();
        renderAlbumGrid();
    }
    function exitSelectMode() {
        state.selectMode = false;
        state.selected = [];
        el('bulk-bar').classList.add('hidden');
        el('select-btn').classList.remove('on');
    }
    function updateBulkBar() { el('bulk-count').textContent = state.selected.length + ' 件'; }

    function toggleSelected(id, card) {
        var i = state.selected.indexOf(id);
        if (i >= 0) state.selected.splice(i, 1); else state.selected.push(id);
        if (card) card.classList.toggle('selected', state.selected.indexOf(id) >= 0);
        updateBulkBar();
    }

    /// 選択したものをまとめて処理する。mode は standard / complete / systemTrash。
    function bulkRemove(mode) {
        if (!state.selected.length) return;
        var ids = state.selected.slice();
        var path, body;
        var affectsLibrary = mode !== 'standard';
        if (mode === 'complete') {
            if (!confirm(ids.length + ' 件をMacから完全に削除します。元に戻せません。よろしいですか？')) return;
            path = '/deleteVideosCompletely';
            body = { videoIds: ids };
        } else if (mode === 'systemTrash') {
            if (!confirm(ids.length + ' 件の実ファイルをMacのゴミ箱へ移動します。リンク元のファイルも対象です。よろしいですか？')) return;
            path = '/moveVideosToSystemTrash';
            body = { videoIds: ids };
        } else {
            // 一括操作はアルバム詳細でしか出せないので、外す先は常に「いま開いているアルバム」。
            // それが ALL VIDEOS / ALL PHOTOS ならサーバー側でゴミ箱行きになる。
            var a = state.currentAlbum;
            if (!a) { toast('アルバムが選ばれていません'); return; }
            var custom = a.name !== 'ALL VIDEOS' && a.name !== 'ALL PHOTOS';
            affectsLibrary = !custom;
            var albumId = a.id;
            if (!custom && !confirm(ids.length + ' 件をゴミ箱へ移動します。（Macのアプリから元に戻せます）')) return;
            path = '/deleteVideos';
            body = { videoIds: ids, albumId: albumId };
        }
        api(path, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        }).then(function (response) {
            if (mode === 'systemTrash') return response.json();
            return { movedVideoIDs: ids, failures: [] };
        }).then(function (result) {
            var removedIDs = mode === 'systemTrash' ? result.movedVideoIDs : ids;
            if (result.failures && result.failures.length) {
                toast(removedIDs.length + ' 件を移動，' + result.failures.length + ' 件は失敗しました');
            } else {
                toast(removedIDs.length + ' 件を処理しました');
            }
            var drop = function (arr) {
                for (var i = arr.length - 1; i >= 0; i--) if (removedIDs.indexOf(arr[i].id) >= 0) arr.splice(i, 1);
            };
            drop(state.albumRaw);
            if (affectsLibrary) {
                drop(state.allVideos); drop(state.allPhotos); drop(state.homeAll); drop(state.homeFiltered);
                drop(state.shortsPool); drop(state.trash); drop(state.queue);
                state.allVideosAt = 0; state.allPhotosAt = 0; state.trashAt = Date.now();
                saveQueue();
            }
            refreshVirtualCounts();
            exitSelectMode();
            renderAlbumGrid();
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('操作に失敗しました');
        });
    }

    function restoreSelectedFromTrash() {
        if (!state.selected.length) return;
        var ids = state.selected.slice();
        api('/trash/restore', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ videoIds: ids })
        }).then(function () {
            state.trash = state.trash.filter(function (item) { return ids.indexOf(item.id) < 0; });
            state.trashAt = Date.now();
            state.albumRaw = state.trash.slice();
            exitSelectMode();
            renderAlbumGrid();
            refreshVirtualCounts();
            state.allVideosAt = 0;
            state.allPhotosAt = 0;
            toast(ids.length + ' 件を復元しました');
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('復元に失敗しました');
        });
    }

    function emptyTrash() {
        if (!state.trash.length) return;
        if (!confirm('ゴミ箱の ' + state.trash.length + ' 件を完全に削除します。元に戻せません。よろしいですか？')) return;
        api('/trash', { method: 'DELETE' }).then(function () {
            state.trash = [];
            state.trashAt = Date.now();
            state.albumRaw = [];
            renderAlbumGrid();
            refreshVirtualCounts();
            toast('ゴミ箱を空にしました');
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('ゴミ箱を空にできませんでした');
        });
    }

    function emptyTrashToSystemTrash() {
        if (!state.trash.length) return;
        var ids = state.trash.map(function (item) { return item.id; });
        if (!confirm('ゴミ箱の ' + ids.length + ' 件の実ファイルをMacのゴミ箱へ移動します。リンク元のファイルも対象です。よろしいですか？')) return;
        api('/moveVideosToSystemTrash', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ videoIds: ids })
        }).then(function (response) { return response.json(); }).then(function (result) {
            var movedIDs = result.movedVideoIDs || [];
            state.trash = state.trash.filter(function (item) { return movedIDs.indexOf(item.id) < 0; });
            state.albumRaw = state.trash.slice();
            state.trashAt = Date.now();
            renderAlbumGrid();
            refreshVirtualCounts();
            if (result.failures && result.failures.length) {
                toast(movedIDs.length + ' 件を移動，' + result.failures.length + ' 件は失敗しました');
            } else {
                toast(movedIDs.length + ' 件をMacのゴミ箱へ移動しました');
            }
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('Macのゴミ箱へ移動できませんでした');
        });
    }

    /// 選択したメディアを別アルバムへ。
    /// サーバー側は「ALL VIDEOS / ALL PHOTOS が移動元なら所属を外さない」ので、そこからは実質「追加」になる。
    function bulkMove() {
        if (!state.selected.length) return;
        var a = state.currentAlbum;
        if (!a) return;
        var ids = state.selected.slice();
        var fromLibrary = a.name === 'ALL VIDEOS' || a.name === 'ALL PHOTOS';
        openAlbumPicker(fromLibrary ? 'どのアルバムに追加しますか' : 'どこへ移動しますか', a.id, function (target) {
            closeAlbumPicker();
            api('/move', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ videoIds: ids, sourceAlbumId: a.id, targetAlbumId: target.id })
            }).then(function () {
                toast(ids.length + ' 件を「' + target.name + '」へ' + (fromLibrary ? '追加' : '移動') + 'しました');
                state.allVideosAt = 0; state.allPhotosAt = 0;
                exitSelectMode();
                return reloadAlbumList().then(function () { return openAlbum(a.id, false); });
            }).catch(function (e) {
                if (!(e instanceof AuthError)) toast('移動に失敗しました');
            });
        });
    }

    // ======================= アップロード =======================
    var ALLOWED_EXT = ['mp4', 'mov', 'm4v', 'avi', 'jpg', 'jpeg', 'png', 'heic', 'webp', 'gif', 'tiff'];
    var uploadXHR = null;
    var uploadAborted = false;

    function extensionOf(name) {
        var m = /\.([^.]+)$/.exec(name || '');
        return m ? m[1].toLowerCase() : '';
    }

    /// サーバーは Swifter がボディを丸ごとメモリに載せてから処理するため、
    /// 上限を超えるものは送る前に弾く（/server/status が上限を教えてくれる）。
    function ensureUploadLimit() {
        if (state.maxUploadBytes) return Promise.resolve(state.maxUploadBytes);
        return api('/server/status').then(function (r) { return r.json(); }).then(function (s) {
            state.maxUploadBytes = s.maxUploadBytes || 0;
            return state.maxUploadBytes;
        }).catch(function () { return 0; });
    }

    function uploadOne(file, albumId, onProgress) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            uploadXHR = xhr;
            xhr.open('POST', '/upload');
            xhr.setRequestHeader('Content-Type', 'application/octet-stream');
            // ヘッダにそのまま日本語は載せられないので、パーセントエンコードして渡す
            xhr.setRequestHeader('X-Filename', encodeURIComponent(file.name));
            if (albumId) xhr.setRequestHeader('X-Album-ID', albumId);
            xhr.upload.onprogress = function (e) {
                if (e.lengthComputable) onProgress(e.loaded / e.total);
            };
            xhr.onload = function () {
                uploadXHR = null;
                if (xhr.status === 401) { showLogin(true); reject(new AuthError()); return; }
                if (xhr.status >= 200 && xhr.status < 300) { resolve(); return; }
                reject(new Error(xhr.status === 413 ? 'サーバーの上限を超えています' : ('エラー ' + xhr.status)));
            };
            xhr.onerror = function () { uploadXHR = null; reject(new Error('通信エラー')); };
            xhr.onabort = function () { uploadXHR = null; reject(new Error('中止しました')); };
            xhr.send(file);
        });
    }

    function startUpload(fileList) {
        var album = state.currentAlbum;
        if (!album || isVirtualAlbumID(album.id)) { toast('アップロード先のアルバムを開いてください'); return; }

        var files = Array.prototype.slice.call(fileList);
        if (!files.length) return;

        ensureUploadLimit().then(function (limit) {
            var queue = [], skipped = [];
            for (var i = 0; i < files.length; i++) {
                if (ALLOWED_EXT.indexOf(extensionOf(files[i].name)) < 0) { skipped.push(files[i].name + '（形式）'); continue; }
                if (limit && files[i].size > limit) { skipped.push(files[i].name + '（サイズ）'); continue; }
                queue.push(files[i]);
            }
            if (skipped.length) toast(skipped.length + ' 件を除外しました: ' + skipped[0]);
            if (!queue.length) return;

            uploadAborted = false;
            el('upload-bar').classList.remove('hidden');
            var done = 0, failed = 0;

            var step = function () {
                if (uploadAborted || done + failed >= queue.length) return Promise.resolve();
                var file = queue[done + failed];
                el('upload-text').textContent =
                    (done + failed + 1) + ' / ' + queue.length + '　' + file.name + '（' + formatBytes(file.size) + '）';
                el('upload-fill').style.width = '0%';
                return uploadOne(file, album.id, function (p) {
                    el('upload-fill').style.width = (p * 100).toFixed(1) + '%';
                }).then(function () { done++; }, function (e) {
                    if (e instanceof AuthError) { uploadAborted = true; return; }
                    failed++;
                    toast(file.name + ': ' + e.message);
                }).then(step);
            };

            return step().then(function () {
                el('upload-bar').classList.add('hidden');
                el('upload-fill').style.width = '0%';
                if (!done) return;
                toast(done + ' 件をアップロードしました' + (failed ? '（' + failed + ' 件失敗）' : ''));
                state.allVideosAt = 0; state.allPhotosAt = 0;
                // サーバーは取り込みを非同期で走らせて即 OK を返すので、少し待ってから読み直す
                setTimeout(function () {
                    reloadAlbumList().then(function () { openAlbum(album.id, false); });
                }, 1800);
            });
        });
    }

    function bulkFavorite() {
        if (!state.selected.length) return;
        // 1つでも未登録があれば「全部つける」、すでに全部ついていれば「全部外す」
        var turnOn = false;
        for (var i = 0; i < state.selected.length; i++) {
            if (!isFavorite(state.selected[i])) { turnOn = true; break; }
        }
        for (var j = 0; j < state.selected.length; j++) {
            if (isFavorite(state.selected[j]) !== turnOn) toggleFavorite(state.selected[j]);
        }
        toast(turnOn ? 'お気に入りに追加しました' : 'お気に入りから外しました');
        renderAlbumGrid();
    }

    // ======================= 再生（ウォッチ画面） =======================
    function playlistFor(origin) {
        if (origin === 'album') return state.albumFiltered;
        if (origin === 'shorts') return state.shortsPool;
        if (origin === 'continue') return state.continueList;
        if (origin === 'queue') return state.queue;
        return state.homeFiltered;
    }

    var conversionTimer = null;

    /// 再生リストの現在行に出す状態ラベル。再生エラー中は「再生中」と出さない。
    /// 写真を開いている間は再生リスト自体が CSS で隠れる（.mode-photo .watch-side）ので、写真用の文言は持たない。
    function nowPlayingLabelText() {
        return state.playbackFailed ? '再生できません' : '再生中';
    }

    /// エラー状態の切り替え。状態は state.playbackFailed だけが持つ。
    /// 描画済みの現在行ラベルの文言だけを差し替える（リスト全体を作り直すとサムネが再取得され、スクロールも戻されるため）。
    function setPlaybackFailed(failed) {
        if (state.playbackFailed === failed) return;
        state.playbackFailed = failed;
        var label = document.querySelector('#up-next .un-item.current .playing-label');
        if (label) label.textContent = nowPlayingLabelText();
    }

    function hidePlaybackError() {
        if (conversionTimer) { clearTimeout(conversionTimer); conversionTimer = null; }
        el('playback-error').classList.add('hidden');
        el('playback-error-progress').textContent = '';
        el('convert-btn').disabled = false;
        setPlaybackFailed(false);
    }

    /// 再生ステージの旧メディア要素を破棄する。先に DOM から外すので、src を消した際に発火する error は
    /// リスナー側の isConnected 判定で確実に捨てられる（同期・非同期のどちらで発火しても）。
    function disposeMediaElement(node) {
        node.remove();
        if (node.tagName === 'VIDEO') { node.pause(); node.removeAttribute('src'); node.load(); }
    }

    function showPlaybackError(media, video) {
        var extension = extensionOf(media.filename).toUpperCase();
        var code = video && video.error ? video.error.code : 0;
        var detail = code === 2
            ? 'ネットワークまたはファイル読み込みでエラーが発生しました。'
            : 'このブラウザは' + (extension ? extension + 'の' : '') + '映像形式またはコーデックを再生できません。';
        el('playback-error-title').textContent = '「' + cleanTitle(media.filename) + '」を再生できませんでした';
        el('playback-error-message').textContent = detail +
            ' 1080pへ変換すると再生できる可能性があります。変換用プロキシはサーバー全体で1本だけ保持されるため、ほかの端末が利用中のプロキシは置き換わります。';
        el('playback-error-progress').textContent = '';
        el('playback-error').classList.remove('hidden');
        setPlaybackFailed(true);
    }

    function prepareCurrentMedia() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media || isPhoto(media)) return;
        var button = el('convert-btn');
        button.disabled = true;
        el('playback-error-progress').textContent = '変換を開始しています…';

        function poll(retry) {
            var path = '/video/' + encodeURIComponent(media.id) + '/prepare?q=1080p' + (retry ? '&retry=true' : '');
            api(path).then(function (response) { return response.json(); }).then(function (result) {
                if (result.state === 'ready') {
                    conversionTimer = null;
                    state.quality = '1080p';
                    el('quality-select').value = '1080p';
                    hidePlaybackError();
                    changeQuality('1080p');
                    toast('変換が完了しました');
                    return;
                }
                if (result.state === 'failed') {
                    conversionTimer = null;
                    button.disabled = false;
                    el('playback-error-progress').textContent = '変換できませんでした: ' + (result.message || 'ファイル形式が変換機能に対応していません');
                    return;
                }
                var percent = Math.max(0, Math.min(100, Math.round((result.progress || 0) * 100)));
                el('playback-error-progress').textContent = '変換中… ' + percent + '%';
                conversionTimer = setTimeout(function () { poll(false); }, 1000);
            }).catch(function (error) {
                conversionTimer = null;
                button.disabled = false;
                if (!(error instanceof AuthError)) el('playback-error-progress').textContent = '変換状態を取得できませんでした';
            });
        }

        poll(true);
    }

    function openMedia(origin, index, push) {
        var list = playlistFor(origin);
        if (!list.length) return;
        if (index < 0) index = 0;
        if (index >= list.length) index = list.length - 1;
        var media = list[index];
        var modal = el('player-modal');
        state.playerOrigin = origin;
        state.playerIndex = index;
        state.isPlayerMini = false;
        modal.classList.remove('mini');
        hidePlaybackError();

        clearPreview();
        pauseShorts();

        var photo = isPhoto(media);
        modal.classList.toggle('mode-photo', photo);
        modal.classList.add('open');
        document.body.style.overflow = 'hidden';

        var stage = el('stage');
        var old = stage.querySelector('#main-media');
        if (old) disposeMediaElement(old);

        el('watch-title').textContent = cleanTitle(media.filename);
        el('watch-title').title = media.filename;
        el('watch-sub').textContent = albumNameOf(media) + ' • ' + timeAgo(media.importDate) +
            (photo ? '' : ' • ' + formatDur(media.duration));
        el('quality-select').classList.toggle('hidden', photo);
        el('watch-shorts').classList.toggle('hidden', photo);
        el('manga-toggle').classList.toggle('hidden', !photo);
        el('stage-mini').classList.toggle('hidden', photo);
        updateMangaButton();

        if (photo) {
            var img = document.createElement('img');
            img.id = 'main-media';
            img.src = mediaURL(media.id);
            img.addEventListener('click', function (e) {
                var w = this.clientWidth || 1;
                var x = e.offsetX;
                if (x < w * 0.3) navMedia(-1);
                else if (x > w * 0.7) navMedia(1);
            });
            stage.appendChild(img);
        } else {
            var video = document.createElement('video');
            video.id = 'main-media';
            video.controls = true;
            video.playsInline = true;
            video.src = mediaURL(media.id, state.quality);
            applyPlaybackToVideo(video);
            var saved = resumeSecondsFor(media);
            video.addEventListener('loadedmetadata', function () {
                // メタデータ読み込みで速度が既定に戻る実装があるので入れ直す
                applyPlaybackToVideo(video);
                if (saved > 2 && (!video.duration || saved < video.duration - 5)) video.currentTime = saved;
            }, { once: true });
            video.addEventListener('canplay', hidePlaybackError, { once: true });
            video.addEventListener('error', function () {
                // 切り替え・閉じる際に破棄した旧 video が遅れて error を発火しても、今の動画の表示に波及させない
                if (!video.isConnected) return;
                showPlaybackError(media, video);
            });
            video.addEventListener('timeupdate', function () {
                if (video.currentTime > 2) setProgress(media.id, video.currentTime);
                updateActiveChapter(video.currentTime);
            });
            // 音量と速度はネイティブのコントロールからも変わるので、そこから拾って覚える
            video.addEventListener('volumechange', function () {
                state.playback.volume = video.volume;
                state.playback.muted = video.muted;
                savePlayback();
            });
            video.addEventListener('ratechange', function () {
                if (video.playbackRate <= 0) return;
                state.playback.rate = video.playbackRate;
                el('rate-select').value = String(video.playbackRate);
                savePlayback();
            });
            video.addEventListener('ended', function () { handleEnded(media, video); });
            stage.appendChild(video);
            video.play().catch(function () {});
        }

        recordHistory(media.id);
        if (state.playedStack[state.playedStack.length - 1] !== index) state.playedStack.push(index);
        if (state.playedStack.length > 200) state.playedStack.shift();

        renderChapters(media);
        updateRemovalButtons();
        updateFavButton();
        updatePlaybackButtons();
        el('pip-btn').classList.toggle('hidden', photo || !document.pictureInPictureEnabled);
        el('playback-actions').classList.toggle('hidden', photo);
        renderUpNext();
        if (push !== false) {
            history.pushState({ view: 'player', origin: origin, index: index, tab: state.tab }, '', '#watch/' + media.id);
        }
    }

    /// 動画を10等分した地点のサムネを並べる。押すとその時間へ飛ぶ。
    function renderChapters(media) {
        var strip = el('chapters');
        state.chapterToken++;
        state.chapterTimes = [];
        strip.innerHTML = '';

        // 写真と、区切っても意味がない短い動画では出さない。
        // サーバーのサムネ名は秒を切り捨てた整数なので、刻みが1秒未満だと同じ絵が並んでしまう。
        if (isPhoto(media) || !(media.duration > CHAPTER_MIN_DURATION)) {
            strip.classList.add('hidden');
            return;
        }
        strip.classList.remove('hidden');

        var html = '';
        for (var i = 0; i < CHAPTER_COUNT; i++) {
            // 先頭は真っ黒なことが多いので少しだけ後ろの絵を使う（飛び先も同じ位置）
            var t = Math.floor(media.duration * (i === 0 ? 0.01 : i / CHAPTER_COUNT));
            state.chapterTimes.push(t);
            html += '<button class="chapter" data-action="seek" data-time="' + t + '" title="' + formatDur(t) + ' へ移動">' +
                '<span class="chapter-thumb"><img alt="" decoding="async" data-src="' +
                    esc(thumbURL(media.id, true) + '&time=' + t) + '"></span>' +
                '<span class="chapter-time">' + formatDur(t) + '</span></button>';
        }
        strip.innerHTML = html;
        loadChaptersInOrder(strip, state.chapterToken);
        updateActiveChapter(0);
    }

    /// 10枚を一斉に要求すると、サーバーのフレーム抽出と接続数を動画本体の読み込みと奪い合う。
    /// 2本ずつ順番に読ませて、再生を妨げないようにする。
    function loadChaptersInOrder(strip, token) {
        var imgs = Array.prototype.slice.call(strip.querySelectorAll('img[data-src]'));
        var cursor = 0;
        function startNext() {
            if (token !== state.chapterToken) return;   // 別の動画に切り替わったら打ち切る
            if (cursor >= imgs.length) return;
            var img = imgs[cursor++];
            var url = img.getAttribute('data-src');
            img.removeAttribute('data-src');
            var advanced = false;
            var advance = function () { if (!advanced) { advanced = true; startNext(); } };
            img.onload = function () { thumbLoaded(img); advance(); };
            img.onerror = function () { thumbFailed(img); advance(); };
            img.src = url;
        }
        startNext();
        startNext();
    }

    function updateActiveChapter(currentTime) {
        var times = state.chapterTimes;
        if (!times.length) return;
        var active = 0;
        for (var i = 0; i < times.length; i++) {
            if (currentTime >= times[i]) active = i;
        }
        var nodes = el('chapters').children;
        for (var j = 0; j < nodes.length; j++) {
            nodes[j].classList.toggle('active', j === active);
        }
    }

    function seekTo(seconds) {
        var video = document.querySelector('#main-media');
        if (!video || video.tagName !== 'VIDEO') return;
        video.currentTime = seconds;
        updateActiveChapter(seconds);
        video.play().catch(function () {});
    }

    function renderUpNext() {
        var list = playlistFor(state.playerOrigin);
        var side = el('up-next');
        var html = '';
        if (state.queue.length && state.playerOrigin !== 'queue') {
            html += '<div class="side-head">次に再生（' + state.queue.length + ' 件）</div>';
            for (var q = 0; q < state.queue.length; q++) {
                var queued = state.queue[q];
                html += '<div class="un-item" role="button" tabindex="0" data-action="play-queue" data-index="' + q + '">' +
                    '<div class="un-thumb">' + imgTag(thumbURL(queued.id, !isPhoto(queued)), '') + '</div>' +
                    '<div class="un-info"><div class="un-title">' + esc(cleanTitle(queued.filename)) + '</div>' +
                    '<div class="un-meta">キュー</div></div></div>';
            }
        }
        html += '<div class="side-head">再生リスト（' + list.length + ' 件）</div>';
        // 長大なライブラリでも重くならないよう、現在位置の前後だけを出す
        var from = Math.max(0, state.playerIndex - 5);
        var to = Math.min(list.length, from + 60);
        for (var i = from; i < to; i++) {
            var v = list[i];
            var photo = isPhoto(v);
            var badge = photo ? '' : (v.duration > 0 ? '<div class="badge-dur chip-on-media">' + formatDur(v.duration) + '</div>' : '');
            var isCurrent = i === state.playerIndex;
            html += '<div class="un-item' + (isCurrent ? ' current' : '') + '"' + (isCurrent ? ' aria-current="true"' : '') + ' role="button" tabindex="0" data-action="play-index" data-index="' + i + '">' +
                '<div class="un-thumb" data-watch-id="' + esc(v.id) + '">' +
                    imgTag(thumbURL(v.id, !photo), '') + badge + watchedBarHTML(v) + '</div>' +
                '<div class="un-info"><div class="un-title">' + esc(cleanTitle(v.filename)) + '</div>' +
                '<div class="un-meta">' + (isCurrent ? '<span class="playing-label">' + nowPlayingLabelText() + '</span> • ' : '') + (photo ? '写真' : '動画') + ' • ' + esc(albumNameOf(v)) + '</div></div></div>';
        }
        side.innerHTML = html;
        var cur = side.querySelector('.un-item.current');
        if (cur) cur.scrollIntoView({ block: 'nearest' });
    }

    /// 次に再生する番号。末尾でリピートしないなら null（＝そこで止まる）。
    function nextIndexFor(i) {
        var list = playlistFor(state.playerOrigin);
        if (!list.length) return null;
        if (state.playback.shuffle && list.length > 1) {
            var j;
            do { j = Math.floor(Math.random() * list.length); } while (j === i);
            return j;
        }
        if (i + 1 < list.length) return i + 1;
        return state.playback.repeat === 'all' ? 0 : null;
    }

    function prevIndexFor(i) {
        var list = playlistFor(state.playerOrigin);
        if (!list.length) return null;
        // シャッフル中は「実際に見てきた順」を辿らないと戻る先がランダムになってしまう
        if (state.playback.shuffle && state.playedStack.length > 1) {
            state.playedStack.pop();
            return state.playedStack[state.playedStack.length - 1];
        }
        if (i - 1 >= 0) return i - 1;
        return state.playback.repeat === 'all' ? list.length - 1 : null;
    }

    function navMedia(dir) {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        // 写真はシャッフル・リピートの対象外。順送りのみ（漫画モードでは左右反転）。
        if (media && isPhoto(media)) {
            if (state.mangaMode) dir = -dir;
            openMedia(state.playerOrigin, state.playerIndex + dir, false);
            replacePlayerState();
            return;
        }
        var target = dir > 0 ? nextIndexFor(state.playerIndex) : prevIndexFor(state.playerIndex);
        if (target === null) return;
        openMedia(state.playerOrigin, target, false);
        replacePlayerState();
    }

    function replacePlayerState() {
        history.replaceState({ view: 'player', origin: state.playerOrigin, index: state.playerIndex, tab: state.tab }, '', location.hash);
    }

    /// 再生し終わったときの分岐。ここが「常に次へ行く」を止める入口。
    function handleEnded(media, video) {
        clearProgress(media.id);
        if (state.playback.repeat === 'one') {
            video.currentTime = 0;
            video.play().catch(function () {});
            return;
        }
        if (!state.playback.autoplay) return;
        if (state.playerOrigin === 'queue') {
            state.queue.splice(state.playerIndex, 1);
            saveQueue();
            if (state.queue.length) {
                openMedia('queue', Math.min(state.playerIndex, state.queue.length - 1), false);
                replacePlayerState();
            }
            return;
        }
        if (state.queue.length) {
            openMedia('queue', 0, false);
            replacePlayerState();
            return;
        }
        var target = nextIndexFor(state.playerIndex);
        if (target === null) return;
        openMedia(state.playerOrigin, target, false);
        replacePlayerState();
    }

    var REPEAT_LABEL = { off: 'リピート: なし', one: 'リピート: 1本', all: 'リピート: 全体' };

    function updatePlaybackButtons() {
        el('autoplay-btn').classList.toggle('on', state.playback.autoplay);
        el('shuffle-btn').classList.toggle('on', state.playback.shuffle);
        var rp = el('repeat-btn');
        rp.textContent = REPEAT_LABEL[state.playback.repeat] || REPEAT_LABEL.off;
        rp.classList.toggle('on', state.playback.repeat !== 'off');
        el('rate-select').value = String(state.playback.rate);
    }

    function applyPlaybackToVideo(video) {
        video.playbackRate = state.playback.rate;
        video.volume = state.playback.volume;
        video.muted = state.playback.muted;
    }

    var QUEUE_KEY = 'mms_queue';

    function saveQueue() {
        if (state.queue.length > 100) state.queue.length = 100;
        writeJSON(QUEUE_KEY, state.queue);
        if (el('player-modal').classList.contains('open')) renderUpNext();
    }

    function addCurrentToQueue() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        for (var i = 0; i < state.queue.length; i++) {
            if (state.queue[i].id === media.id) { toast('すでにキューに入っています'); return; }
        }
        state.queue.push(media);
        saveQueue();
        toast('次に再生するキューへ追加しました');
    }

    function addCurrentToPlaylist() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        var sourceID = libraryAlbumIDFor(media);
        if (!sourceID) { toast('ライブラリアルバムが見つかりません'); return; }
        openAlbumPicker('追加先のプレイリストを選んでください', sourceID, function (target) {
            closeAlbumPicker();
            api('/move', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ videoIds: [media.id], sourceAlbumId: sourceID, targetAlbumId: target.id })
            }).then(function () {
                toast('「' + target.name + '」へ追加しました');
                return reloadAlbumList();
            }).catch(function (error) {
                if (!(error instanceof AuthError)) toast('プレイリストへ追加できませんでした');
            });
        }, true);
    }

    function copyCurrentLink() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        var url = location.origin + location.pathname + '#watch/' + encodeURIComponent(media.id);
        var copied = function () { toast('共有リンクをコピーしました'); };
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(url).then(copied).catch(function () { fallbackCopy(url, copied); });
        } else {
            fallbackCopy(url, copied);
        }
    }

    function fallbackCopy(value, done) {
        var input = document.createElement('textarea');
        input.value = value;
        input.style.position = 'fixed';
        input.style.opacity = '0';
        document.body.appendChild(input);
        input.select();
        try { document.execCommand('copy'); done(); } catch (error) { toast('リンクをコピーできませんでした'); }
        input.remove();
    }

    function downloadCurrentMedia() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        var anchor = document.createElement('a');
        anchor.href = mediaURL(media.id, 'original');
        anchor.download = media.filename || 'media';
        document.body.appendChild(anchor);
        anchor.click();
        anchor.remove();
    }

    function minimizePlayer() {
        var modal = el('player-modal');
        var media = modal.querySelector('#main-media');
        if (!media || media.tagName !== 'VIDEO') return;
        state.isPlayerMini = true;
        modal.classList.add('mini');
        document.body.style.overflow = '';
        history.replaceState({ view: 'tab', tab: state.tab }, '', '#' + state.tab);
    }

    function expandPlayer() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        state.isPlayerMini = false;
        el('player-modal').classList.remove('mini');
        document.body.style.overflow = 'hidden';
        history.pushState({ view: 'player', origin: state.playerOrigin, index: state.playerIndex, tab: state.tab }, '', '#watch/' + media.id);
    }

    function closePlayer(useHistory) {
        var stage = el('stage');
        var media = stage.querySelector('#main-media');
        hidePlaybackError();
        if (media) disposeMediaElement(media);
        // 閉じたあともサムネ読み込みが走り続けないよう、合図の番号を進めて打ち切る
        state.chapterToken++;
        state.chapterTimes = [];
        el('chapters').innerHTML = '';
        el('chapters').classList.add('hidden');
        el('player-modal').classList.remove('open');
        el('player-modal').classList.remove('mini');
        state.isPlayerMini = false;
        document.body.style.overflow = '';
        // 一覧は作り直さず、視聴済みバーと「続きを見る」だけ更新する（スクロール位置を保つため）
        refreshCardOverlays();
        if (state.tab === 'continue') renderContinue();
        if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(function () {});
        // 「見るのをやめた瞬間」が視聴位置として一番価値が高い。
        // デバウンス待ちの2秒の間に別端末へ移られると取りこぼすので、ここだけは即座に送る。
        pushSync(true);
        if (useHistory !== false) history.back();
    }

    function updateMangaButton() {
        var btn = el('manga-toggle');
        btn.textContent = state.mangaMode ? '漫画モード' : '通常モード';
        btn.style.color = state.mangaMode ? 'var(--text)' : '';
    }

    function changeQuality(q) {
        state.quality = q;
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        var video = document.querySelector('#main-media');
        if (!media || isPhoto(media) || !video) return;
        hidePlaybackError();
        var t = video.currentTime, wasPlaying = !video.paused;
        video.src = mediaURL(media.id, q);
        video.addEventListener('loadedmetadata', function () {
            video.currentTime = t;
            if (wasPlaying) video.play().catch(function () {});
        }, { once: true });
    }

    function updateFavButton() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        var on = isFavorite(media.id);
        var btn = el('fav-btn');
        btn.textContent = on ? 'お気に入り済み' : 'お気に入り';
        btn.classList.toggle('fav-on', on);
    }

    function formatBytes(n) {
        if (!n || n <= 0) return '—';
        var units = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, v = n;
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
        return (i === 0 ? v : v.toFixed(1)) + ' ' + units[i];
    }
    function formatDateTime(iso) {
        if (!iso) return '—';
        var d = new Date(iso);
        if (isNaN(d.getTime())) return '—';
        return d.getFullYear() + '/' + (d.getMonth() + 1) + '/' + d.getDate() + ' ' +
            ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
    }

    function showInfo() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        var node = document.querySelector('#main-media');
        var dims = '—';
        if (node) {
            if (node.videoWidth) dims = node.videoWidth + ' × ' + node.videoHeight;
            else if (node.naturalWidth) dims = node.naturalWidth + ' × ' + node.naturalHeight;
        }
        var rows = [
            ['ファイル名', media.filename],
            ['種類', isPhoto(media) ? '写真' : '動画'],
            ['解像度', dims],
            ['長さ', isPhoto(media) ? '—' : formatDur(media.duration)],
            ['サイズ', formatBytes(media.fileSize)],
            ['アルバム', albumNameOf(media)],
            ['追加日', formatDateTime(media.importDate)],
            ['撮影日', formatDateTime(media.creationDate)],
            ['更新日', formatDateTime(media.modificationDate)],
            ['最後に開いた日', formatDateTime(media.accessDate)],
            ['視聴位置', isPhoto(media) ? '—' : (formatDur(resumeSecondsFor(media)) + ' / ' + formatDur(media.duration))],
            ['ID', media.id]
        ];
        var html = '';
        for (var i = 0; i < rows.length; i++) {
            html += '<div class="info-row"><div class="info-key">' + esc(rows[i][0]) + '</div>' +
                '<div class="info-val">' + esc(rows[i][1]) + '</div></div>';
        }
        el('info-title').textContent = cleanTitle(media.filename);
        el('info-body').innerHTML = html;
        el('info-modal').classList.add('open');
    }

    function libraryAlbumIDFor(media) {
        var want = isPhoto(media) ? 'ALL PHOTOS' : 'ALL VIDEOS';
        for (var i = 0; i < state.albums.length; i++) if (state.albums[i].name === want) return state.albums[i].id;
        return null;
    }

    /// 通常アルバムを開いているときだけ「そのアルバムから外す」になる。
    /// それ以外（ホーム／ALL VIDEOS・ALL PHOTOS）は「ゴミ箱へ」。
    function removalContext(media) {
        var a = state.currentAlbum;
        if (state.playerOrigin === 'album' && a && a.id === 'TRASH') {
            return { albumId: null, label: 'ゴミ箱にあります', done: '', confirm: null };
        }
        if (state.playerOrigin === 'album' && a && a.name !== 'ALL VIDEOS' && a.name !== 'ALL PHOTOS') {
            return { albumId: a.id, label: 'アルバムから外す', done: '「' + a.name + '」から外しました', confirm: null };
        }
        return {
            albumId: libraryAlbumIDFor(media),
            label: 'ゴミ箱へ',
            done: 'ゴミ箱へ移動しました',
            confirm: 'このメディアをゴミ箱へ移動します。（Macのアプリから元に戻せます）'
        };
    }

    function updateRemovalButtons() {
        var media = playlistFor(state.playerOrigin)[state.playerIndex];
        if (!media) return;
        var ctx = removalContext(media);
        var btn = el('trash-btn');
        btn.textContent = ctx.label;
        var inTrash = state.playerOrigin === 'album' && state.currentAlbum && state.currentAlbum.id === 'TRASH';
        // ALL VIDEOS / ALL PHOTOS が見つからないときは押しても意味がないので隠す
        btn.classList.toggle('hidden', !ctx.albumId || inTrash);
        el('restore-btn').classList.toggle('hidden', !inTrash);
        el('playlist-btn').classList.toggle('hidden', inTrash);
        el('share-btn').classList.toggle('hidden', inTrash);
    }

    function restoreCurrentFromTrash() {
        var list = playlistFor(state.playerOrigin);
        var media = list[state.playerIndex];
        if (!media) return;
        api('/trash/restore', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ videoIds: [media.id] })
        }).then(function () {
            var removeFrom = function (items) {
                for (var i = items.length - 1; i >= 0; i--) if (items[i].id === media.id) items.splice(i, 1);
            };
            removeFrom(state.trash);
            removeFrom(state.albumRaw);
            removeFrom(state.albumFiltered);
            state.trashAt = Date.now();
            state.allVideosAt = 0;
            state.allPhotosAt = 0;
            refreshVirtualCounts();
            toast('ゴミ箱から復元しました');
            if (!list.length) { closePlayer(); return; }
            openMedia(state.playerOrigin, Math.min(state.playerIndex, list.length - 1), false);
        }).catch(function (error) {
            if (!(error instanceof AuthError)) toast('復元に失敗しました');
        });
    }

    /// mode は standard / complete / systemTrash。
    function removeCurrent(mode) {
        var list = playlistFor(state.playerOrigin);
        var media = list[state.playerIndex];
        if (!media) return;

        var path, body, doneMsg;
        var affectsLibrary = mode !== 'standard';
        if (mode === 'complete') {
            if (!confirm('このメディアをMacから完全に削除します。元に戻せません。よろしいですか？')) return;
            path = '/deleteVideosCompletely';
            body = { videoIds: [media.id] };
            doneMsg = '完全に削除しました';
        } else if (mode === 'systemTrash') {
            if (!confirm('このメディアの実ファイルをMacのゴミ箱へ移動します。リンク元のファイルも対象です。よろしいですか？')) return;
            path = '/moveVideosToSystemTrash';
            body = { videoIds: [media.id] };
            doneMsg = '実ファイルをMacのゴミ箱へ移動しました';
        } else {
            var ctx = removalContext(media);
            if (!ctx.albumId) { toast('移動先のアルバムが見つかりません'); return; }
            if (ctx.confirm && !confirm(ctx.confirm)) return;
            path = '/deleteVideos';
            body = { videoIds: [media.id], albumId: ctx.albumId };
            doneMsg = ctx.done;
            affectsLibrary = ctx.label === 'ゴミ箱へ';
        }

        api(path, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        }).then(function (response) {
            if (mode === 'systemTrash') return response.json();
            return { movedVideoIDs: [media.id], failures: [] };
        }).then(function (result) {
            if (mode === 'systemTrash' && result.movedVideoIDs.indexOf(media.id) < 0) {
                var reason = result.failures && result.failures.length ? result.failures[0].reason : '不明なエラー';
                toast('Macのゴミ箱へ移動できませんでした: ' + reason);
                return;
            }
            toast(doneMsg);
            var removeFrom = function (arr) {
                for (var i = arr.length - 1; i >= 0; i--) if (arr[i].id === media.id) arr.splice(i, 1);
            };
            removeFrom(state.albumRaw); removeFrom(state.albumFiltered);
            if (affectsLibrary) {
                removeFrom(state.allVideos); removeFrom(state.allPhotos); removeFrom(state.homeAll); removeFrom(state.homeFiltered);
                removeFrom(state.shortsPool); removeFrom(state.trash); removeFrom(state.queue);
                state.allVideosAt = 0; state.allPhotosAt = 0; state.trashAt = Date.now();
                saveQueue();
            }
            refreshVirtualCounts();
            clearProgress(media.id);
            if (!list.length) { closePlayer(); return; }
            openMedia(state.playerOrigin, Math.min(state.playerIndex, list.length - 1), false);
            if (state.tab === 'home') rerenderHomeFeed();
            if (state.tab === 'continue') renderContinue();
            if (state.currentAlbum) renderAlbumGrid();
        }).catch(function (e) {
            if (!(e instanceof AuthError)) toast('操作に失敗しました');
        });
    }

    // ======================= ショート =======================
    function ensureShorts() {
        if (state.shortsPool.length) { resumeShorts(); return; }
        el('shorts-state').classList.remove('hidden');
        loadAllVideos(false).then(function (vids) {
            if (!vids.length) {
                el('shorts-state').innerHTML = '<div>再生できる動画がありません</div>';
                return;
            }
            state.shortsPool = shuffle(vids);
            state.shortsSource = 'ALL VIDEOS';
            state.shortsIndex = 0;
            el('shorts-state').classList.add('hidden');
            playShortAt(0);
        }).catch(function (e) {
            if (e instanceof AuthError) return;
            el('shorts-state').innerHTML = '<div>読み込みに失敗しました</div>';
        });
    }

    function startShortsWith(videoId, pool, sourceName) {
        var list = pool && pool.length ? pool.filter(function (v) { return !isPhoto(v); }) : state.shortsPool;
        if (!list.length) { toast('再生できる動画がありません'); return; }
        var start = 0;
        if (videoId) {
            var picked = null, rest = [];
            for (var i = 0; i < list.length; i++) {
                if (list[i].id === videoId && !picked) picked = list[i];
                else rest.push(list[i]);
            }
            list = picked ? [picked].concat(shuffle(rest)) : shuffle(list);
        } else if (pool) {
            list = shuffle(list);
        }
        state.shortsPool = list;
        if (sourceName) state.shortsSource = sourceName;
        state.shortsIndex = start;
        el('shorts-state').classList.add('hidden');
        showTab('shorts');
        playShortAt(start);
    }

    function playShortAt(i) {
        var pool = state.shortsPool;
        if (!pool.length) return;
        state.shortsIndex = ((i % pool.length) + pool.length) % pool.length;
        var v = pool[state.shortsIndex];
        var video = el('shorts-video');

        state.shortsClipStart = (v.duration > SHORTS_CLIP) ? Math.random() * (v.duration - SHORTS_CLIP) : 0;
        state.shortsReady = false;
        state.isScrubbing = false;
        el('shorts-bar').classList.remove('scrubbing');
        setShortsProgress(0);
        el('shorts-count').textContent = (state.shortsIndex + 1) + ' / ' + pool.length + ' • ' + state.shortsSource;
        el('shorts-title').textContent = cleanTitle(v.filename);
        recordHistory(v.id);
        renderShortsRail();   // ハートの状態は動画ごとに変わる

        video.muted = state.shortsMuted;
        video.src = mediaURL(v.id);
        video.load();
        tryPlayShorts();
        preloadNextShort();
    }

    function tryPlayShorts() {
        var video = el('shorts-video');
        var p = video.play();
        if (p && p.catch) {
            p.catch(function () {
                // 音ありの自動再生が拒否されたらミュートで再挑戦する（ブラウザの既定動作）
                if (!video.muted) {
                    state.shortsMuted = true;
                    localStorage.setItem('shortsMuted', 'true');
                    video.muted = true;
                    renderShortsRail();
                    video.play().catch(function () {});
                }
            });
        }
        el('shorts-pause').classList.remove('show');
    }

    // 次の1本をこっそり読み込み、送ったときの待ちを短くする
    var preloadEl = null;
    function preloadNextShort() {
        if (state.shortsPool.length < 2) return;
        var next = state.shortsPool[(state.shortsIndex + 1) % state.shortsPool.length];
        setTimeout(function () {
            if (state.tab !== 'shorts') return;
            if (!preloadEl) {
                preloadEl = document.createElement('video');
                preloadEl.muted = true;
                preloadEl.preload = 'auto';
                preloadEl.style.display = 'none';
                document.body.appendChild(preloadEl);
            }
            var url = mediaURL(next.id);
            if (preloadEl.getAttribute('src') !== url) { preloadEl.src = url; preloadEl.load(); }
        }, 1500);
    }

    /// いま再生しているクリップの長さ（秒）。まだ読めていなければ 0。
    function shortsClipLength() {
        var video = el('shorts-video');
        if (!video.duration || !isFinite(video.duration)) return 0;
        return Math.max(0.1, Math.min(SHORTS_CLIP, video.duration - state.shortsClipStart));
    }

    function setShortsProgress(pct) {
        var p = Math.max(0, Math.min(1, pct)) * 100;
        el('shorts-bar-fill').style.width = p + '%';
        el('shorts-bar-knob').style.left = p + '%';
    }

    /// precise=false はドラッグ中。見た目は毎回更新しつつ、実際のシークは間引いて
    /// 追従を軽くする（連続シークは読み込みが詰まりやすい）。
    var lastScrubSeek = 0;
    function scrubShortsTo(pct, precise) {
        setShortsProgress(pct);
        var clipLen = shortsClipLength();
        if (!clipLen) return;
        var now = Date.now();
        if (!precise && now - lastScrubSeek < 120) return;
        lastScrubSeek = now;

        var video = el('shorts-video');
        // 末尾ちょうどに合わせると自動送りが即発火してしまうので少し手前で止める
        var target = state.shortsClipStart + clipLen * Math.min(pct, 0.995);
        if (!precise && typeof video.fastSeek === 'function') {
            try { video.fastSeek(target); return; } catch (err) {}
        }
        try { video.currentTime = target; } catch (err) {}
    }

    function nextShort() { playShortAt(state.shortsIndex + 1); }
    function prevShort() { playShortAt(state.shortsIndex - 1); }

    function toggleShortsPlay() {
        var video = el('shorts-video');
        var zoom = el('shorts-zoom');
        if (zoom && !zoom.classList.contains('hidden')) { zoom.classList.add('hidden'); return; }
        if (video.paused) { tryPlayShorts(); }
        else { video.pause(); el('shorts-pause').classList.add('show'); }
    }

    function pauseShorts() {
        var video = el('shorts-video');
        if (video && !video.paused) video.pause();
    }
    function resumeShorts() {
        if (!state.shortsPool.length || !el('shorts-video').getAttribute('src')) return;
        // タブを離れている間に幅が変わっていることがあるので、枠を測り直してから再生する
        applyShortsZoom();
        updateZoomHint();
        tryPlayShorts();
    }

    var PHONE_ASPECT = 9 / 16;

    function applyShortsZoom() {
        var video = el('shorts-video');
        var frame = el('shorts-frame');
        var val = state.shortsZoom / 100;
        var videoAspect = (video.videoWidth && video.videoHeight) ? (video.videoWidth / video.videoHeight) : 0;

        if (isDesktop()) {
            // Mac: 映像を切り取って拡大するのではなく「枠そのもの」を動画の形に近づける。
            // 高さは常に目一杯なので、横長の動画ほど枠が横に広がって大きく見える。
            video.style.transform = 'scale(1)';
            var stage = el('shorts-stage');
            var railW = el('shorts-rail-d').offsetWidth || 48;
            var availH = Math.max(200, stage.clientHeight - 32);
            var availW = Math.max(200, stage.clientWidth - railW - 26);
            var target = videoAspect
                ? PHONE_ASPECT + (videoAspect - PHONE_ASPECT) * val
                : PHONE_ASPECT;
            target = Math.max(0.3, target);
            var w = availH * target, h = availH;
            if (w > availW) { w = availW; h = w / target; }
            frame.style.width = Math.round(w) + 'px';
            frame.style.height = Math.round(h) + 'px';
            return;
        }

        // スマホ: 枠は画面いっぱいのまま、映像を拡大して余白を埋める（従来どおり）
        frame.style.width = '';
        frame.style.height = '';
        if (!val) { video.style.transform = 'scale(1)'; return; }
        var viewAspect = frame.clientWidth / Math.max(1, frame.clientHeight);
        var srcAspect = videoAspect || viewAspect;
        var fill = srcAspect > viewAspect
            ? frame.clientHeight / (frame.clientWidth / srcAspect)
            : frame.clientWidth / (frame.clientHeight * srcAspect);
        fill = Math.max(1, fill);
        video.style.transform = 'scale(' + (1 + (fill - 1) * val) + ')';
    }

    function updateZoomHint() {
        var hint = el('shorts-zoom-hint');
        if (!hint) return;
        hint.textContent = isDesktop()
            ? (state.shortsZoom === 0 ? '縦型の枠（9:16）' : '枠を広げて大きく表示 ' + state.shortsZoom + '%')
            : (state.shortsZoom === 0 ? '全体を表示' : '拡大して余白を埋める ' + state.shortsZoom + '%');
    }

    function railButton(id, title, svg, on) {
        return '<button class="rail-btn' + (on ? ' on' : '') + '" data-rail="' + id + '" title="' + title + '">' + svg + '</button>';
    }
    var ICO_MUTE = '<svg class="ico" viewBox="0 0 24 24"><path d="M3.6 2.2 2.2 3.6 7.6 9H3v6h4l5 5v-6.8l4.2 4.2c-.6.5-1.4.9-2.2 1.1v2.1c1.4-.3 2.7-.9 3.7-1.8l2.1 2.1 1.4-1.4zM12 4 9.9 6.1 12 8.2zm7 8c0 .8-.2 1.6-.5 2.3l1.5 1.5c.6-1.1 1-2.4 1-3.8 0-4-2.8-7.4-6.5-8.2v2.1C17.1 6.7 19 9.1 19 12"/></svg>';
    var ICO_SOUND = '<svg class="ico" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.47 4.47 0 0 0 16.5 12M14 3.23v2.06c2.9.86 5 3.54 5 6.71s-2.1 5.85-5 6.71v2.06c4-.91 7-4.49 7-8.77s-3-7.86-7-8.77"/></svg>';
    var ICO_UP = '<svg class="ico" viewBox="0 0 24 24"><path d="m12 8-6 6 1.4 1.4L12 10.8l4.6 4.6L18 14z"/></svg>';
    var ICO_DOWN = '<svg class="ico" viewBox="0 0 24 24"><path d="M7.4 8.6 6 10l6 6 6-6-1.4-1.4L12 13.2z"/></svg>';
    var ICO_ZOOM = '<svg class="ico" viewBox="0 0 24 24"><path d="M4 4h6v2H6v4H4zm10 0h6v6h-2V6h-4zm4 10h2v6h-6v-2h4zM4 14h2v4h4v2H4z"/></svg>';
    var ICO_FULL = '<svg class="ico" viewBox="0 0 24 24"><path d="M10 8.6 15.5 12 10 15.4zM21 6.5c-.2-1.7-.9-2.9-2.7-3.1C16.4 3.1 13.9 3 12 3s-4.4.1-6.3.4C3.9 3.6 3.2 4.8 3 6.5 2.9 7.7 2.8 9.3 2.8 12s.1 4.3.2 5.5c.2 1.7.9 2.9 2.7 3.1 1.9.3 4.4.4 6.3.4s4.4-.1 6.3-.4c1.8-.2 2.5-1.4 2.7-3.1.1-1.2.2-2.8.2-5.5s-.1-4.3-.2-5.5"/></svg>';
    var ICO_SHUFFLE = '<svg class="ico" viewBox="0 0 24 24"><path d="M10.6 8.6 7 5H3v2h3.2l3 3zM14 5v2h2.6l-9 9H3v2h5.4l9.6-9.6V13h2V5zm2.6 11H14v2h2.6l-1.3 1.3 1.4 1.4L21 17l-4.3-3.7-1.4 1.4z"/></svg>';

    var ICO_HEART = '<svg class="ico" viewBox="0 0 24 24"><path d="M12 21S3.5 14.6 3.5 9.2A4.7 4.7 0 0 1 12 6.3a4.7 4.7 0 0 1 8.5 2.9C20.5 14.6 12 21 12 21"/></svg>';

    function currentShort() { return state.shortsPool[state.shortsIndex] || null; }

    function renderShortsRail() {
        var cur = currentShort();
        var favOn = cur ? shortsFavIndex(cur.id) >= 0 : false;
        var html =
            railButton('shortfav', favOn ? 'お気に入りから外す' : 'お気に入りに追加', ICO_HEART, favOn) +
            railButton('mute', state.shortsMuted ? 'ミュート解除' : 'ミュート', state.shortsMuted ? ICO_MUTE : ICO_SOUND, false) +
            railButton('zoom', 'サイズ調整', ICO_ZOOM, state.shortsZoom > 0) +
            railButton('full', 'この動画を通常再生', ICO_FULL, false) +
            railButton('shuffle', 'シャッフルし直す', ICO_SHUFFLE, false) +
            railButton('prev', '前へ', ICO_UP, false) +
            railButton('next', '次へ', ICO_DOWN, false);
        el('shorts-rail-m').innerHTML = html;
        el('shorts-rail-d').innerHTML = html;
    }

    function onRailAction(action) {
        var video = el('shorts-video');
        if (action === 'mute') {
            state.shortsMuted = !state.shortsMuted;
            localStorage.setItem('shortsMuted', String(state.shortsMuted));
            video.muted = state.shortsMuted;
            if (!state.shortsMuted && video.paused) tryPlayShorts();
            renderShortsRail();
        } else if (action === 'shortfav') {
            var cur = currentShort();
            if (!cur) return;
            // 「どのクリップが良かったか」を残したいので開始位置ごと覚える
            var on = toggleShortsFav(cur.id, state.shortsClipStart);
            renderShortsRail();
            toast(on ? 'ショートのお気に入りに追加しました' : 'お気に入りから外しました');
        } else if (action === 'zoom') {
            el('shorts-zoom').classList.toggle('hidden');
            updateZoomHint();
        } else if (action === 'full') {
            // ショートの並びをそのまま再生リストにしてウォッチ画面を重ねる。
            // ホームの再生リストには触らない（表示中のカードと再生対象がずれるため）。
            if (!state.shortsPool[state.shortsIndex]) return;
            openMedia('shorts', state.shortsIndex, true);
        } else if (action === 'shuffle') {
            loadAllVideos(true).then(function (vids) {
                if (!vids.length) return;
                state.shortsPool = shuffle(vids);
                state.shortsSource = 'ALL VIDEOS';
                playShortAt(0);
                toast('シャッフルしました');
            }).catch(function () {});
        } else if (action === 'prev') prevShort();
        else if (action === 'next') nextShort();
    }

    // ======================= イベント配線 =======================
    function bindShortsMedia() {
        var video = el('shorts-video');

        video.addEventListener('loadedmetadata', function () {
            if (state.shortsClipStart > 0) {
                try { video.currentTime = state.shortsClipStart; } catch (e) {}
            }
            state.shortsReady = true;
            applyShortsZoom();
        });

        video.addEventListener('timeupdate', function () {
            // ドラッグ中は再生位置にバーを引き戻さない。自動送りもここで止める
            // （終端付近を掴んだだけで次の動画へ飛んでしまうため）。
            if (state.isScrubbing) return;
            var clipLen = shortsClipLength();
            if (!clipLen) return;
            var elapsed = video.currentTime - state.shortsClipStart;
            if (elapsed >= clipLen) { nextShort(); return; }
            setShortsProgress(elapsed / clipLen);
        });

        video.addEventListener('ended', function () { nextShort(); });
        video.addEventListener('error', function () {
            if (state.shortsPool.length > 1) setTimeout(nextShort, 600);
        });
        video.addEventListener('play', function () { el('shorts-pause').classList.remove('show'); });

        el('shorts-tap').addEventListener('click', toggleShortsPlay);

        // シークバーは「押した位置へジャンプ」＋「掴んだままドラッグ」の両方に対応する。
        // マウスもタッチも同じ扱いにしたいのでポインタイベントを使う。
        var bar = el('shorts-bar');

        function pctAt(clientX) {
            var rect = bar.getBoundingClientRect();
            if (rect.width <= 0) return 0;
            return Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
        }

        bar.addEventListener('pointerdown', function (e) {
            if (!shortsClipLength()) return;
            e.preventDefault();
            e.stopPropagation();
            state.isScrubbing = true;
            bar.classList.add('scrubbing');
            // 掴んだ指／カーソルがバーの外へ出ても追従させる
            try { bar.setPointerCapture(e.pointerId); } catch (err) {}
            scrubShortsTo(pctAt(e.clientX), false);
        });

        bar.addEventListener('pointermove', function (e) {
            if (!state.isScrubbing) return;
            e.preventDefault();
            scrubShortsTo(pctAt(e.clientX), false);
        });

        function endScrub(e) {
            if (!state.isScrubbing) return;
            e.stopPropagation();
            state.isScrubbing = false;
            bar.classList.remove('scrubbing');
            try { bar.releasePointerCapture(e.pointerId); } catch (err) {}
            scrubShortsTo(pctAt(e.clientX), true);   // 離した位置へ正確に合わせる
        }
        bar.addEventListener('pointerup', endScrub);
        bar.addEventListener('pointercancel', function () {
            state.isScrubbing = false;
            bar.classList.remove('scrubbing');
        });

        // ホイールは連続で飛ばないよう間引く
        var wheelLock = 0;
        el('panel-shorts').addEventListener('wheel', function (e) {
            e.preventDefault();
            var now = Date.now();
            if (now - wheelLock < 500) return;
            if (Math.abs(e.deltaY) < 30) return;
            wheelLock = now;
            if (e.deltaY > 0) nextShort(); else prevShort();
        }, { passive: false });

        var touchY = 0, touchX = 0;
        el('panel-shorts').addEventListener('touchstart', function (e) {
            touchY = e.changedTouches[0].screenY;
            touchX = e.changedTouches[0].screenX;
        }, { passive: true });
        el('panel-shorts').addEventListener('touchend', function (e) {
            if (state.isScrubbing) return;   // シークバー操作を送り／戻しと取り違えない
            var dy = e.changedTouches[0].screenY - touchY;
            var dx = e.changedTouches[0].screenX - touchX;
            if (Math.abs(dy) < 60 || Math.abs(dx) > Math.abs(dy)) return;
            if (dy < 0) nextShort(); else prevShort();
        }, { passive: true });

        var zoomBox = document.createElement('div');
        zoomBox.className = 'shorts-zoom hidden';
        zoomBox.id = 'shorts-zoom';
        zoomBox.innerHTML = '<label id="shorts-zoom-label">表示サイズ</label>' +
            '<input type="range" id="shorts-zoom-range" min="0" max="100" value="' + state.shortsZoom + '">' +
            '<div class="hint" id="shorts-zoom-hint"></div>';
        el('shorts-frame').appendChild(zoomBox);
        zoomBox.addEventListener('click', function (e) { e.stopPropagation(); });
        el('shorts-zoom-range').addEventListener('input', function () {
            state.shortsZoom = parseInt(this.value, 10);
            localStorage.setItem('shortsZoom', String(state.shortsZoom));
            applyShortsZoom();
            updateZoomHint();
        });
        updateZoomHint();

        // 非表示のときに測ると 0 になるので、ショートタブを見ているときだけ測り直す
        window.addEventListener('resize', function () {
            if (state.tab !== 'shorts') return;
            applyShortsZoom();
            updateZoomHint();
        });
        document.addEventListener('visibilitychange', function () {
            if (document.hidden) pauseShorts();
        });
    }

    function bindGlobal() {
        // 同期のライフサイクル。定期ポーリングは LAN 常時接続の小さなサーバーには過剰なので、
        // 「タブを離れるとき送る／戻ってきたとき引く」だけにする。
        // これで「スマホで一時停止 → Mac に移動」という実際の使い方をほぼ全部カバーできる。
        // ショート用の visibilitychange は bindShortsMedia 側にあるので、そちらは触らず別に足す。
        document.addEventListener('visibilitychange', function () {
            if (document.hidden) { pushSync(true); return; }
            if (Date.now() - state.syncLastPullAt > SYNC_PULL_TTL) pullSync();
        });
        // unload では fetch が中断される。beacon だけが最後の1回を通せる。
        window.addEventListener('pagehide', function () { flushSyncBeacon(); });

        // ナビ
        var items = document.querySelectorAll('.nav-item');
        for (var i = 0; i < items.length; i++) {
            (function (btn) {
                btn.addEventListener('click', function () {
                    var tab = btn.dataset.tab;
                    // 同じタブの再タップは無視。ただしアルバム詳細を開いていれば一覧に戻す。
                    if (tab === state.tab && !(tab === 'albums' && state.currentAlbum)) return;
                    showTab(tab);
                });
            })(items[i]);
        }

        el('search-toggle').addEventListener('click', function () {
            var w = el('search-wrap');
            w.classList.toggle('open');
            if (w.classList.contains('open')) el('global-search').focus();
        });

        var searchTimer = null;
        el('global-search').addEventListener('input', function () {
            clearTimeout(searchTimer);
            searchTimer = setTimeout(function () {
                if (state.tab === 'home') applyHomeFilter();
                else if (state.tab === 'continue') renderContinue();
                else if (state.tab === 'albums') { if (state.currentAlbum) renderAlbumGrid(); else filterAlbums(); }
            }, 200);
        });

        el('refresh-btn').addEventListener('click', function () {
            var btn = this;
            btn.classList.add('spinning');
            state.allVideos = []; state.allVideosAt = 0; state.homeAll = [];
            state.trash = []; state.trashAt = 0;
            el('albums-list').dataset.loaded = '';
            loadAlbums(true).then(function () {
                if (state.tab === 'home') { el('home-feed').innerHTML = ''; ensureHome(); }
                if (state.tab === 'albums') { if (state.currentAlbum) openAlbum(state.currentAlbum.id, false); else ensureAlbums(); }
                if (state.tab === 'continue') ensureContinue();
                if (state.tab === 'shorts') { state.shortsPool = []; ensureShorts(); }
                toast('更新しました');
            }).catch(function () {}).then(function () {
                setTimeout(function () { btn.classList.remove('spinning'); }, 400);
            });
        });

        el('shutdown-btn').addEventListener('click', function () {
            if (!confirm('Ark Serverアプリを完全に終了します。よろしいですか？')) return;
            api('/server/shutdown', { method: 'POST' }).then(function () {
                toast('サーバーを終了します');
            }).catch(function (error) {
                if (!(error instanceof AuthError)) toast('サーバーを終了できませんでした');
            });
        });

        el('detail-back').addEventListener('click', function () { history.back(); });
        el('sort-select').addEventListener('change', renderAlbumGrid);
        el('rename-album-btn').addEventListener('click', renameCurrentAlbum);
        el('delete-album-btn').addEventListener('click', deleteCurrentAlbum);
        el('empty-trash-btn').addEventListener('click', emptyTrash);
        el('empty-trash-system-btn').addEventListener('click', emptyTrashToSystemTrash);
        el('album-shorts-btn').addEventListener('click', function () {
            if (!state.currentAlbum) return;
            var vids = state.albumFiltered.filter(function (v) { return !isPhoto(v); });
            if (!vids.length) { toast('再生できる動画がありません'); return; }
            startShortsWith(null, vids, state.currentAlbum.name);
        });

        // 一覧のクリックはまとめて拾う（大量のカードにハンドラを付けない）
        document.addEventListener('click', function (e) {
            var target = e.target.closest ? e.target.closest('[data-action], [data-rail]') : null;
            if (!target) return;
            if (target.dataset.rail) { onRailAction(target.dataset.rail); return; }
            var action = target.dataset.action;
            // 選択モード中のカードは再生せずチェックの付け外しにする
            if (state.selectMode && action === 'play-album') {
                toggleSelected(target.dataset.id, target);
                return;
            }
            if (action === 'play-home') openMedia('home', parseInt(target.dataset.index, 10), true);
            else if (action === 'play-album') openMedia('album', parseInt(target.dataset.index, 10), true);
            else if (action === 'play-index') { openMedia(state.playerOrigin, parseInt(target.dataset.index, 10), false); }
            else if (action === 'play-queue') { openMedia('queue', parseInt(target.dataset.index, 10), true); }
            else if (action === 'seek') seekTo(parseFloat(target.dataset.time));
            else if (action === 'play-continue') openMedia('continue', parseInt(target.dataset.index, 10), true);
            else if (action === 'open-album') openAlbum(target.dataset.id, true);
            else if (action === 'play-short') startShortsWith(target.dataset.id, state.homeAll, 'おすすめショート');
        });

        // Mac のホバープレビュー
        if (canHover) {
            el('home-feed').addEventListener('mouseover', function (e) {
                var thumb = e.target.closest ? e.target.closest('.feed-thumb') : null;
                if (thumb && !thumb.querySelector('video')) attachPreview(thumb);
            });
            el('home-feed').addEventListener('mouseout', function (e) {
                var thumb = e.target.closest ? e.target.closest('.feed-thumb') : null;
                if (thumb && (!e.relatedTarget || !thumb.contains(e.relatedTarget))) clearPreview();
            });
        }

        // プレイヤー
        el('stage-close').addEventListener('click', function () { closePlayer(state.isPlayerMini ? false : undefined); });
        el('stage-mini').addEventListener('click', minimizePlayer);
        el('stage-expand').addEventListener('click', expandPlayer);
        el('convert-btn').addEventListener('click', prepareCurrentMedia);
        el('arrow-prev').addEventListener('click', function () { navMedia(-1); });
        el('arrow-next').addEventListener('click', function () { navMedia(1); });
        el('quality-select').addEventListener('change', function () { changeQuality(this.value); });
        el('trash-btn').addEventListener('click', function () { removeCurrent('standard'); });
        el('restore-btn').addEventListener('click', restoreCurrentFromTrash);
        el('purge-btn').addEventListener('click', function () { removeCurrent('complete'); });
        el('system-trash-btn').addEventListener('click', function () { removeCurrent('systemTrash'); });
        el('queue-btn').addEventListener('click', addCurrentToQueue);
        el('playlist-btn').addEventListener('click', addCurrentToPlaylist);
        el('share-btn').addEventListener('click', copyCurrentLink);
        el('download-btn').addEventListener('click', downloadCurrentMedia);

        // --- お気に入り・詳細情報 ---
        el('fav-btn').addEventListener('click', function () {
            var media = playlistFor(state.playerOrigin)[state.playerIndex];
            if (!media) return;
            var on = toggleFavorite(media.id);
            updateFavButton();
            refreshCardOverlays();
            toast(on ? 'お気に入りに追加しました' : 'お気に入りから外しました');
        });
        el('info-btn').addEventListener('click', showInfo);
        el('info-close').addEventListener('click', function () { el('info-modal').classList.remove('open'); });
        el('info-modal').addEventListener('click', function (e) {
            if (e.target === this) this.classList.remove('open');
        });

        // --- 再生の設定 ---
        el('autoplay-btn').addEventListener('click', function () {
            state.playback.autoplay = !state.playback.autoplay;
            savePlayback(); updatePlaybackButtons();
            toast(state.playback.autoplay ? '自動再生: オン' : '自動再生: オフ');
        });
        el('repeat-btn').addEventListener('click', function () {
            var order = ['off', 'one', 'all'];
            state.playback.repeat = order[(order.indexOf(state.playback.repeat) + 1) % order.length];
            savePlayback(); updatePlaybackButtons();
        });
        el('shuffle-btn').addEventListener('click', function () {
            state.playback.shuffle = !state.playback.shuffle;
            savePlayback(); updatePlaybackButtons();
            toast(state.playback.shuffle ? 'シャッフル: オン' : 'シャッフル: オフ');
        });
        el('rate-select').addEventListener('change', function () {
            state.playback.rate = parseFloat(this.value) || 1;
            savePlayback();
            var v = document.querySelector('#main-media');
            if (v && v.tagName === 'VIDEO') v.playbackRate = state.playback.rate;
        });
        el('pip-btn').addEventListener('click', function () {
            var v = document.querySelector('#main-media');
            if (!v || v.tagName !== 'VIDEO') return;
            if (document.pictureInPictureElement) { document.exitPictureInPicture().catch(function () {}); return; }
            if (!v.requestPictureInPicture) { toast('この環境では使えません'); return; }
            v.requestPictureInPicture().catch(function () { toast('ピクチャインピクチャを開始できません'); });
        });

        // --- 複数選択 ---
        el('select-btn').addEventListener('click', function () {
            if (state.selectMode) { exitSelectMode(); renderAlbumGrid(); }
            else enterSelectMode();
        });
        el('bulk-cancel').addEventListener('click', function () { exitSelectMode(); renderAlbumGrid(); });
        el('bulk-all').addEventListener('click', function () {
            var all = state.selected.length === state.albumFiltered.length;
            state.selected = all ? [] : state.albumFiltered.map(function (v) { return v.id; });
            updateBulkBar();
            renderAlbumGrid();
        });
        el('bulk-fav').addEventListener('click', bulkFavorite);
        el('bulk-move').addEventListener('click', bulkMove);
        el('bulk-restore').addEventListener('click', restoreSelectedFromTrash);

        // --- アップロード ---
        el('upload-btn').addEventListener('click', function () { el('file-input').click(); });
        el('file-input').addEventListener('change', function () {
            startUpload(this.files);
            this.value = '';   // 同じファイルを続けて選べるように空にしておく
        });
        el('upload-cancel').addEventListener('click', function () {
            uploadAborted = true;
            if (uploadXHR) uploadXHR.abort();
            el('upload-bar').classList.add('hidden');
            toast('アップロードを中止しました');
        });

        var dz = el('album-detail');
        var dragDepth = 0;
        dz.addEventListener('dragenter', function (e) {
            if (!state.currentAlbum || isVirtualAlbumID(state.currentAlbum.id)) return;
            e.preventDefault(); dragDepth++; dz.classList.add('dragging');
        });
        dz.addEventListener('dragover', function (e) {
            if (!state.currentAlbum || isVirtualAlbumID(state.currentAlbum.id)) return;
            e.preventDefault(); e.dataTransfer.dropEffect = 'copy';
        });
        dz.addEventListener('dragleave', function () {
            dragDepth = Math.max(0, dragDepth - 1);
            if (!dragDepth) dz.classList.remove('dragging');
        });
        dz.addEventListener('drop', function (e) {
            if (!state.currentAlbum || isVirtualAlbumID(state.currentAlbum.id)) return;
            e.preventDefault();
            dragDepth = 0; dz.classList.remove('dragging');
            if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) startUpload(e.dataTransfer.files);
        });

        // --- アルバムの選択シート / 作成 ---
        el('picker-list').addEventListener('click', function (e) {
            var btn = e.target.closest ? e.target.closest('[data-pick]') : null;
            if (!btn || !pickerChoice) return;
            for (var i = 0; i < state.albums.length; i++) {
                if (state.albums[i].id === btn.dataset.pick) { pickerChoice(state.albums[i]); return; }
            }
        });
        el('picker-close').addEventListener('click', closeAlbumPicker);
        el('picker-modal').addEventListener('click', function (e) { if (e.target === this) closeAlbumPicker(); });
        el('create-ok').addEventListener('click', submitCreateAlbum);
        el('create-cancel').addEventListener('click', function () { el('create-modal').classList.remove('open'); });
        el('create-modal').addEventListener('click', function (e) { if (e.target === this) this.classList.remove('open'); });
        el('create-name').addEventListener('keydown', function (e) { if (e.key === 'Enter') submitCreateAlbum(); });
        el('bulk-trash').addEventListener('click', function () { bulkRemove('standard'); });
        el('bulk-purge').addEventListener('click', function () { bulkRemove('complete'); });
        el('bulk-system-trash').addEventListener('click', function () { bulkRemove('systemTrash'); });
        albumObserver.observe(el('album-sentinel'));
        el('manga-toggle').addEventListener('click', function () {
            state.mangaMode = !state.mangaMode;
            localStorage.setItem('isMangaMode', String(state.mangaMode));
            updateMangaButton();
        });
        el('watch-shorts').addEventListener('click', function () {
            var v = playlistFor(state.playerOrigin)[state.playerIndex];
            if (!v) return;
            closePlayer(false);
            startShortsWith(v.id, playlistFor(state.playerOrigin), state.currentAlbum && state.playerOrigin === 'album' ? state.currentAlbum.name : 'おすすめ');
        });

        // ログイン
        el('login-btn').addEventListener('click', submitPIN);
        el('pin-input').addEventListener('keydown', function (e) { if (e.key === 'Enter') submitPIN(); });

        feedObserver.observe(el('home-sentinel'));
    }

    function bindKeyboard() {
        // カードは div なので、Enter / Space で押せるようにする（Tab で辿れる）
        document.addEventListener('keydown', function (e) {
            if (e.key !== 'Enter' && e.key !== ' ') return;
            var node = document.activeElement;
            if (!node || !node.dataset || !node.dataset.action) return;
            e.preventDefault();
            node.click();
        });

        document.addEventListener('keydown', function (e) {
            var tag = document.activeElement ? document.activeElement.tagName : '';
            if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
                if (e.key === 'Escape') document.activeElement.blur();
                return;
            }

            var playerOpen = el('player-modal').classList.contains('open');
            if (playerOpen) {
                var media = document.querySelector('#main-media');
                var isVideo = media && media.tagName === 'VIDEO';
                if (e.key === 'Escape') { e.preventDefault(); closePlayer(state.isPlayerMini ? false : undefined); return; }
                if (!isVideo) {
                    if (e.key === 'ArrowLeft') { e.preventDefault(); navMedia(-1); }
                    if (e.key === 'ArrowRight') { e.preventDefault(); navMedia(1); }
                    if (e.key === 'f' || e.key === 'F') { e.preventDefault(); toggleFullscreen(document.documentElement); }
                    return;
                }
                switch (e.key.toLowerCase()) {
                    case ' ': case 'k':
                        e.preventDefault(); if (media.paused) media.play(); else media.pause(); break;
                    case 'j': e.preventDefault(); media.currentTime = Math.max(0, media.currentTime - 5); break;
                    case 'l': e.preventDefault(); media.currentTime = Math.min(media.duration || 0, media.currentTime + 5); break;
                    case 'arrowleft':
                        e.preventDefault();
                        if (e.shiftKey) navMedia(-1); else media.currentTime = Math.max(0, media.currentTime - 5);
                        break;
                    case 'arrowright':
                        e.preventDefault();
                        if (e.shiftKey) navMedia(1); else media.currentTime = Math.min(media.duration || 0, media.currentTime + 5);
                        break;
                    case 'arrowup': e.preventDefault(); media.volume = Math.min(1, media.volume + 0.1); break;
                    case 'arrowdown': e.preventDefault(); media.volume = Math.max(0, media.volume - 0.1); break;
                    case 'm': e.preventDefault(); media.muted = !media.muted; break;
                    case 'f': e.preventDefault(); toggleFullscreen(media); break;
                    case 'n': e.preventDefault(); navMedia(1); break;
                    case 'p': e.preventDefault(); navMedia(-1); break;
                    case 'i': e.preventDefault(); if (state.isPlayerMini) expandPlayer(); else minimizePlayer(); break;
                    case 'q': e.preventDefault(); addCurrentToQueue(); break;
                }
                return;
            }

            if (state.tab === 'shorts') {
                if (e.key === 'ArrowUp') { e.preventDefault(); prevShort(); return; }
                if (e.key === 'ArrowDown') { e.preventDefault(); nextShort(); return; }
                if (e.key === ' ') { e.preventDefault(); toggleShortsPlay(); return; }
                if (e.key === 'm' || e.key === 'M') { e.preventDefault(); onRailAction('mute'); return; }
                if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
                    e.preventDefault();
                    var clipLen = shortsClipLength();
                    if (!clipLen) return;
                    var video = el('shorts-video');
                    var elapsed = video.currentTime - state.shortsClipStart;
                    var step = e.key === 'ArrowRight' ? 5 : -5;
                    scrubShortsTo((elapsed + step) / clipLen, true);
                    return;
                }
            }

            // タブ切り替えショートカット（1/2/3）
            if (e.key === '1') showTab('home');
            if (e.key === '2') showTab('shorts');
            if (e.key === '3') showTab('continue');
            if (e.key === '4') showTab('albums');
            if (e.key === '/') { e.preventDefault(); el('search-wrap').classList.add('open'); el('global-search').focus(); }
        });
    }

    function toggleFullscreen(node) {
        if (!document.fullscreenElement) {
            var req = node.requestFullscreen || node.webkitRequestFullscreen;
            if (req) req.call(node).catch(function () {});
        } else {
            var exit = document.exitFullscreen || document.webkitExitFullscreen;
            if (exit) exit.call(document).catch(function () {});
        }
    }

    // ======================= 起動 =======================
    function boot(afterLogin) {
        loadAlbums(true).then(function () {
            el('login-modal').classList.remove('open');
            // 同期の往復で起動を遅らせない。投げっぱなしにして、解決したら
            // mergeSyncDoc → refreshCardOverlays で後から追いつく。
            // その直後に「ローカルにしかない分」を押し戻す経路が、そのまま初回移行の吸い上げになる。
            pullSync().then(function () { if (state.syncDirty) pushSync(true); }).catch(function () {});
            renderShortsRail();
            applyLocation(!afterLogin);
        }).catch(function (e) {
            if (e instanceof AuthError) return;
            el('home-state').innerHTML = '<div>サーバーに接続できません</div>';
        });
    }

    // 「ローカルを読む → 移行 → GET でマージ → PUT」の順序が、初回同期でサーバーの空データに
    // 上書きされないための本体。順序が安全性そのものなので入れ替えないこと。
    state.progress = loadProgress();
    state.queue = readJSON(QUEUE_KEY, []);
    state.history = readJSON(HISTORY_KEY, []);
    state.historyRemoved = readJSON(HISTORY_REMOVED_KEY, {});
    migrateLocalSync();                     // 旧形式(配列)の favorites / shortsFavs をマップへ
    state.favMarks = readJSON(FAV_KEY, {});
    state.shortsFavMarks = readJSON(SHORTFAV_KEY, {});
    rebuildFavorites();
    rebuildShortsFavs();
    state.syncDirty = true;                 // サーバーが空でも自分の分が必ず1回押し戻されるように
    var savedPlayback = readJSON(PLAYBACK_KEY, null);
    if (savedPlayback) {
        for (var pk in state.playback) {
            if (Object.prototype.hasOwnProperty.call(savedPlayback, pk)) state.playback[pk] = savedPlayback[pk];
        }
    }
    updatePlaybackButtons();
    bindGlobal();
    bindShortsMedia();
    bindKeyboard();
    renderShortsRail();
    history.replaceState({ view: 'tab', tab: 'home' }, '', location.hash || '#home');
    boot(false);
    </script>
    </body>
    </html>
    """#
}
