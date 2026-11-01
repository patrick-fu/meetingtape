(function () {
  'use strict';

  const i18n = {
    en: {
      page_title: "MeetingTape — Native Mac Meeting Recorder & Live Captions",
      page_desc: "A native Mac meeting recorder with live captions. System and microphone audio capture, searchable library, and Markdown export.",
      skip_to_content: "Skip to main content",
      nav_companion: "Companion",
      nav_library: "Library",
      nav_transcripts: "Transcripts",
      nav_download: "Download",
      theme_system: "System appearance",
      theme_light: "Light appearance",
      theme_dark: "Dark appearance",
      navigation: "Main navigation",
      appearance: "Appearance",
      reference_links: "Product links",
      github_source: "GitHub source code",
      companion_modes: "Caption window preview",
      image_library: "MeetingTape library with demo recordings, playback and bilingual captions",
      image_mini: "MeetingTape compact recorder showing a demo recording with bilingual captions",
      image_expanded: "MeetingTape expanded caption window with a demo conversation and translations",
      image_transcript: "MeetingTape demo transcript with model comparison and Markdown export",
      hero_headline_1: "Stay present.",
      hero_headline_2: "Keep the conversation.",
      hero_lead: "Your Mac meeting recorder. Capture the conversation, follow live captions, and keep audio and transcripts together.",
      hero_download_btn: "Download for Apple Silicon",
      hero_github_btn: "GitHub",
      hero_requirements: "Apple Silicon · macOS 14.2+",
      scene1_title: "Stay present while the conversation unfolds.",
      scene1_desc: "Once recording starts, a compact floating window keeps the controls at hand without taking over your screen. Original and translated captions appear together, and the expanded view keeps more history close by.",
      scene1_tab_mini: "Mini Window",
      scene1_tab_expanded: "Expanded Captions",
      scene1_mini_caption: "Check the timer and live waveform at a glance, pin above your call, or stop in one click.",
      scene1_expanded_caption: "Read the original and translation together, with more of the conversation in view.",
      scene2_title: "Find the conversation again.",
      scene2_desc: "Search, rename, favorite, and play every recording from one quiet place. The context stays with the file, so you spend less time hunting and more time using what was said.",
      scene3_title: "Turn the recording into a document you can share.",
      scene3_desc: "Read the transcript beside the audio and click any timestamp to hear that moment again. Compare versions made with local Qwen or MOSS models, or connect your Doubao key for cloud transcription. Export the versions you want as clean Markdown.",
      step1_title: "Download & Open",
      step1_desc: "Download MeetingTape for Apple Silicon and grant standard macOS recording permissions.",
      step2_title: "Record",
      step2_desc: "Start recording from the menu bar or library window whenever conversation begins.",
      step3_title: "Revisit & Export",
      step3_desc: "Revisit audio in your library, compare transcription models, and export clean Markdown.",
      cta_title: "Record the meeting. Leave with something you can use.",
      footer_requirements_note: "Requires Apple Silicon Mac with macOS 14.2+ (Apple translation requires macOS 26+).",
      footer_guide: "User Guide",
      footer_setup: "Transcription Setup",
      footer_release: "Release Notes",
      footer_license: "MIT License",
    },
    zh: {
      page_title: "MeetingTape — Mac 原生会议录音与实时字幕",
      page_desc: "专为 Mac 打造的会议录音应用。支持系统与麦克风录音、实时双语字幕、资料库回听与 Markdown 导出。",
      skip_to_content: "跳转至主要内容",
      nav_companion: "浮窗",
      nav_library: "资料库",
      nav_transcripts: "转写",
      nav_download: "下载",
      theme_system: "跟随系统",
      theme_light: "浅色外观",
      theme_dark: "深色外观",
      navigation: "主导航",
      appearance: "外观",
      reference_links: "产品链接",
      github_source: "GitHub 源码",
      companion_modes: "字幕窗口预览",
      image_library: "MeetingTape 资料库中的演示录音、回听与双语字幕",
      image_mini: "MeetingTape 精简录音窗，显示演示录音与双语字幕",
      image_expanded: "MeetingTape 展开字幕窗中的演示对话与译文",
      image_transcript: "MeetingTape 演示转写中的模型对比与 Markdown 导出",
      hero_headline_1: "专注对话。",
      hero_headline_2: "让记录随行。",
      hero_lead: "MeetingTape 同时记录系统与麦克风声音，实时字幕相伴，会议录音自动保存在资料库中随时回看。",
      hero_download_btn: "下载 Apple Silicon 版",
      hero_github_btn: "GitHub",
      hero_requirements: "Apple Silicon · macOS 14.2+",
      scene1_title: "专注对话，浮窗轻伴身旁。",
      scene1_desc: "录音时，小窗陪伴在侧。原文与译文同时呈现，展开就能查看更多对话。",
      scene1_tab_mini: "极简小窗",
      scene1_tab_expanded: "展开字幕",
      scene1_mini_caption: "动态波形与录制计时一目了然，可置顶于会议窗口上方，点击即停。",
      scene1_expanded_caption: "原文与译文对照阅读，回看刚才的对话。",
      scene2_title: "会议录音，随时可溯。",
      scene2_desc: "在统一整洁的资料库中搜索、重命名、加星标与回听。音频与字幕上下文保存在一起，回溯更省心。",
      scene3_title: "对比模型转写，导出 Markdown。",
      scene3_desc: "在音频旁查看转写，点击时间戳随时重播该段语音。已保存录音支持使用本地 Qwen 或 MOSS 模型转写，亦可接入个人豆包 Key 进行云端识别，一键导出干净的 Markdown 文档。",
      step1_title: "下载并安装",
      step1_desc: "下载 Apple Silicon 版安装镜像，授予基础 macOS 录制权限。",
      step2_title: "一键开录",
      step2_desc: "通话开始时，从菜单栏或资料库开始录音。",
      step3_title: "复盘与导出",
      step3_desc: "会后在资料库中回听，对比本地与云端模型转写，一键导出 Markdown 分享给团队。",
      cta_title: "记录会议。留下真正有用的信息。",
      footer_requirements_note: "需配备 Apple Silicon 芯片的 Mac，macOS 14.2+（系统本地翻译需 macOS 26+）。",
      footer_guide: "使用指南",
      footer_setup: "转写说明",
      footer_release: "版本历史",
      footer_license: "MIT 协议",
    }
  };

  let currentLang = 'en';

  function detectInitialLang() {
    try {
      const stored = localStorage.getItem('meetingtape.language');
      if (stored === 'zh' || stored === 'en') return stored;
    } catch (e) {}

    const langs = navigator.languages || [navigator.language || 'en'];
    for (let i = 0; i < langs.length; i++) {
      const l = (langs[i] || '').toLowerCase();
      if (l.startsWith('zh')) return 'zh';
      if (l.startsWith('en')) return 'en';
    }
    return 'en';
  }

  function applyLanguage(lang, persist = false) {
    currentLang = (lang === 'zh') ? 'zh' : 'en';
    const dict = i18n[currentLang];

    document.documentElement.lang = (currentLang === 'zh') ? 'zh-CN' : 'en';
    document.title = dict.page_title;

    const metaDesc = document.querySelector('meta[name="description"]');
    if (metaDesc) metaDesc.setAttribute('content', dict.page_desc);

    const ogTitle = document.querySelector('meta[property="og:title"]');
    if (ogTitle) ogTitle.setAttribute('content', dict.page_title);
    const ogDesc = document.querySelector('meta[property="og:description"]');
    if (ogDesc) ogDesc.setAttribute('content', dict.page_desc);

    const translatables = document.querySelectorAll('[data-i18n]');
    translatables.forEach(function (el) {
      const key = el.getAttribute('data-i18n');
      if (dict[key]) {
        el.textContent = dict[key];
      }
    });

    for (const [dataAttribute, targetAttribute] of [['data-i18n-label', 'aria-label'], ['data-i18n-alt', 'alt'], ['data-i18n-title', 'title']]) {
      document.querySelectorAll('[' + dataAttribute + ']').forEach(function (el) {
        const key = el.getAttribute(dataAttribute);
        if (dict[key]) el.setAttribute(targetAttribute, dict[key]);
      });
    }
    for (const [name, value] of [['twitter:title', dict.page_title], ['twitter:description', dict.page_desc]]) {
      const meta = document.querySelector('meta[name="' + name + '"]');
      if (meta) meta.setAttribute('content', value);
    }

    const langBtn = document.getElementById('lang-toggle-btn');
    const langLabel = document.getElementById('lang-label');
    if (langBtn && langLabel) {
      if (currentLang === 'en') {
        langLabel.textContent = '中文';
        langBtn.setAttribute('aria-label', 'Switch to 简体中文');
        langBtn.setAttribute('title', 'Switch to 简体中文');
      } else {
        langLabel.textContent = 'EN';
        langBtn.setAttribute('aria-label', '切换为 English');
        langBtn.setAttribute('title', '切换为 English');
      }
    }

    const a11yStatus = document.getElementById('a11y-status');
    if (a11yStatus && persist) {
      a11yStatus.textContent = (currentLang === 'zh') ? '已切换为简体中文' : 'Language switched to English';
    }

    if (persist) {
      try { localStorage.setItem('meetingtape.language', currentLang); } catch (e) {}
    }
  }

  let currentTheme = 'system';

  function initTheme() {
    try {
      const saved = localStorage.getItem('meetingtape.appearance');
      if (saved === 'light' || saved === 'dark' || saved === 'system') {
        currentTheme = saved;
      }
    } catch (e) {}

    applyTheme(currentTheme);

    const darkMatcher = window.matchMedia('(prefers-color-scheme: dark)');
    if (darkMatcher && darkMatcher.addEventListener) {
      darkMatcher.addEventListener('change', function () {
        if (currentTheme === 'system') {
          document.documentElement.setAttribute('data-theme', 'system');
        }
      });
    }
  }

  function applyTheme(theme) {
    currentTheme = theme;
    document.documentElement.setAttribute('data-theme', theme);

    const themeButtons = document.querySelectorAll('.theme-btn');
    themeButtons.forEach(function (btn) {
      const val = btn.getAttribute('data-theme-val');
      const isSelected = (val === theme);
      btn.setAttribute('aria-pressed', isSelected ? 'true' : 'false');
    });

    try {
      localStorage.setItem('meetingtape.appearance', theme);
    } catch (e) {}
  }

  let activeCompanionMode = 'mini';

  function setCompanionMode(mode) {
    activeCompanionMode = mode;
    const cardMini = document.getElementById('card-mini');
    const cardExpanded = document.getElementById('card-expanded');
    const btnMini = document.getElementById('btn-mode-mini');
    const btnExpanded = document.getElementById('btn-mode-expanded');

    if (!cardMini || !cardExpanded) return;

    if (mode === 'mini') {
      cardMini.classList.add('active');
      cardExpanded.classList.remove('active');
      if (btnMini) {
        btnMini.classList.add('active');
        btnMini.setAttribute('aria-pressed', 'true');
      }
      if (btnExpanded) {
        btnExpanded.classList.remove('active');
        btnExpanded.setAttribute('aria-pressed', 'false');
      }
    } else {
      cardExpanded.classList.add('active');
      cardMini.classList.remove('active');
      if (btnExpanded) {
        btnExpanded.classList.add('active');
        btnExpanded.setAttribute('aria-pressed', 'true');
      }
      if (btnMini) {
        btnMini.classList.remove('active');
        btnMini.setAttribute('aria-pressed', 'false');
      }
    }
  }

  function initScrollLinkedCompanion() {
    const track = document.getElementById('companion-scroll-track');
    const hero = document.getElementById('hero');
    if (!track) return;
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
    const frames = document.querySelectorAll('.product-frame');
    let observer;
    let ticking = false;

    function update() {
      ticking = false;
      if (reduced.matches) return;
      const rect = track.getBoundingClientRect();
      const travel = track.offsetHeight - window.innerHeight;
      const progress = travel > 0 ? Math.max(0, Math.min(1, -rect.top / travel)) : 0;
      track.style.setProperty('--scene-offset', (progress * 32).toFixed(2) + 'px');
      track.style.setProperty('--mini-scale', (1 - progress * 0.08).toFixed(3));
      track.style.setProperty('--expanded-scale', (0.94 + progress * 0.06).toFixed(3));
      if (progress >= 0.5 && activeCompanionMode !== 'expanded') setCompanionMode('expanded');
      else if (progress < 0.3 && activeCompanionMode !== 'mini') setCompanionMode('mini');
      if (hero) {
        const amount = Math.min(1, Math.max(0, -hero.getBoundingClientRect().top / hero.offsetHeight));
        hero.style.setProperty('--hero-offset', (-amount * 28).toFixed(2) + 'px');
      }
    }

    function schedule() {
      if (!ticking && !reduced.matches) {
        ticking = true;
        window.requestAnimationFrame(update);
      }
    }

    function configureMotion() {
      document.documentElement.classList.toggle('has-motion', !reduced.matches);
      if (observer) observer.disconnect();
      if (!reduced.matches && 'IntersectionObserver' in window) {
        observer = new IntersectionObserver(function (entries) {
          entries.forEach(function (entry) {
            if (entry.isIntersecting) {
              entry.target.classList.add('is-visible');
              observer.unobserve(entry.target);
            }
          });
        }, { threshold: 0.08 });
        frames.forEach(function (frame) { observer.observe(frame); });
      } else {
        frames.forEach(function (frame) { frame.classList.add('is-visible'); });
      }
      schedule();
    }

    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    if (reduced.addEventListener) reduced.addEventListener('change', configureMotion);
    configureMotion();
  }

  function init() {
    document.documentElement.classList.add('has-js');
    const initialLang = detectInitialLang();
    applyLanguage(initialLang);

    const langToggleBtn = document.getElementById('lang-toggle-btn');
    if (langToggleBtn) {
      langToggleBtn.addEventListener('click', function () {
        const nextLang = (currentLang === 'en') ? 'zh' : 'en';
        applyLanguage(nextLang, true);
      });
    }

    initTheme();
    const themeButtons = document.querySelectorAll('.theme-btn');
    themeButtons.forEach(function (btn) {
      btn.addEventListener('click', function () {
        const chosen = btn.getAttribute('data-theme-val');
        applyTheme(chosen);
      });
    });

    const btnMini = document.getElementById('btn-mode-mini');
    const btnExpanded = document.getElementById('btn-mode-expanded');
    if (btnMini) {
      btnMini.addEventListener('click', function () {
        setCompanionMode('mini');
      });
    }
    if (btnExpanded) {
      btnExpanded.addEventListener('click', function () {
        setCompanionMode('expanded');
      });
    }
    initScrollLinkedCompanion();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
