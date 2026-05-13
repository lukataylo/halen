(() => {
  'use strict';

  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------- Scroll reveal ---------- */
  const revealEls = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !prefersReducedMotion) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    revealEls.forEach((el) => io.observe(el));
  } else {
    revealEls.forEach((el) => el.classList.add('is-visible'));
  }

  /* ---------- Install snippet copy ---------- */
  const snippet = document.querySelector('.install-snippet');
  if (snippet) {
    const copyBtn = snippet.querySelector('.snippet-copy');
    const label = snippet.querySelector('.snippet-copy-label');
    copyBtn?.addEventListener('click', async () => {
      const cmd = snippet.dataset.copy || '';
      try {
        await navigator.clipboard.writeText(cmd);
        copyBtn.classList.add('copied');
        if (label) label.textContent = 'copied';
        setTimeout(() => {
          copyBtn.classList.remove('copied');
          if (label) label.textContent = 'copy';
        }, 1600);
      } catch (_) {
        copyBtn.classList.add('copied');
        if (label) label.textContent = 'select & copy';
      }
    });
  }

  /* ---------- Plugin toggle list ---------- */
  const pluginList = document.getElementById('pluginList');
  const pluginCount = document.getElementById('pluginCount');
  if (pluginList && pluginCount) {
    const refreshCount = () => {
      const on = pluginList.querySelectorAll('.plugin-row[data-on="true"]').length;
      pluginCount.textContent = String(on);
    };
    pluginList.querySelectorAll('.plugin-row').forEach((row) => {
      row.addEventListener('click', () => {
        const on = row.getAttribute('data-on') === 'true';
        row.setAttribute('data-on', on ? 'false' : 'true');
        row.setAttribute('aria-pressed', on ? 'false' : 'true');
        refreshCount();
      });
    });
    refreshCount();
  }

  /* ---------- Tone-classifier demo ---------- */
  const SAMPLES = {
    hostile: {
      text: "This is absolutely unacceptable. I'm furious about how you handled this and I expect better immediately.",
      label: 'hostile',
      confidence: '0.94',
      cls: 'tone-hostile',
      icon: '!',
      popoverColor: 'rgba(255, 110, 110, 0.18)',
      popoverText: '#FF8B8B',
    },
    irritated: {
      text: "I've already asked twice. Can someone actually take ownership of this before end of day?",
      label: 'irritated',
      confidence: '0.81',
      cls: 'tone-irritated',
      icon: '!',
      popoverColor: 'rgba(255, 176, 91, 0.18)',
      popoverText: '#FFB05B',
    },
    passive: {
      text: "Thanks so much for finally getting back to me. Really appreciate it being only a week.",
      label: 'passive-aggressive',
      confidence: '0.76',
      cls: 'tone-passive',
      icon: '~',
      popoverColor: 'rgba(242, 216, 90, 0.18)',
      popoverText: '#F2D85A',
    },
    neutral: {
      text: "Sharing the updated timeline below. Happy to walk through it on a call whenever works for you.",
      label: 'neutral',
      confidence: '0.92',
      cls: 'tone-neutral',
      icon: '✓',
      popoverColor: 'rgba(37, 194, 110, 0.18)',
      popoverText: '#88E2B1',
    },
  };

  const draftEl = document.getElementById('typingDraft');
  const toneLabel = document.getElementById('toneLabel');
  const toneConf = document.getElementById('toneConf');
  const popover = document.getElementById('tonePopover');
  const popoverLabel = document.getElementById('popoverLabel');
  const popoverIcon = document.getElementById('popoverIcon');
  const pills = document.querySelectorAll('.demo-pill');
  const approveBtn = document.getElementById('approveBtn');
  const rephraseBtn = document.getElementById('rephraseBtn');

  let typingTimer = null;
  let labelTimer = null;
  let popoverTimer = null;

  const setLabel = (sample) => {
    if (!toneLabel) return;
    toneLabel.className = 't-label ' + sample.cls;
    toneLabel.textContent = sample.label;
    if (toneConf) toneConf.textContent = `confidence ${sample.confidence}`;
  };

  const showPopover = (sample) => {
    if (!popover || !popoverLabel || !popoverIcon) return;
    popoverLabel.textContent = sample.label;
    popoverIcon.textContent = sample.icon;
    popoverIcon.style.background = sample.popoverColor;
    popoverIcon.style.color = sample.popoverText;
    const labelSpan = popover.querySelector('.popover-text strong span');
    if (labelSpan) labelSpan.style.color = sample.popoverText;
    popover.classList.add('is-open');
  };

  const hidePopover = () => popover?.classList.remove('is-open');

  const playSample = (key) => {
    const sample = SAMPLES[key];
    if (!sample || !draftEl) return;

    if (typingTimer) clearInterval(typingTimer);
    if (labelTimer) clearTimeout(labelTimer);
    if (popoverTimer) clearTimeout(popoverTimer);

    draftEl.textContent = '';
    toneLabel.className = 't-label';
    toneLabel.textContent = '…';
    if (toneConf) toneConf.textContent = 'thinking';
    hidePopover();

    let i = 0;
    const speed = prefersReducedMotion ? 0 : 22;
    if (prefersReducedMotion) {
      draftEl.textContent = sample.text;
      setLabel(sample);
      if (key !== 'neutral') showPopover(sample);
      return;
    }
    typingTimer = setInterval(() => {
      i += 1;
      draftEl.textContent = sample.text.slice(0, i);
      if (i >= sample.text.length) {
        clearInterval(typingTimer);
        typingTimer = null;
        labelTimer = setTimeout(() => setLabel(sample), 360);
        if (key !== 'neutral') {
          popoverTimer = setTimeout(() => showPopover(sample), 820);
        }
      }
    }, speed);
  };

  pills.forEach((pill) => {
    pill.addEventListener('click', () => {
      pills.forEach((p) => p.classList.remove('is-active'));
      pill.classList.add('is-active');
      playSample(pill.dataset.sample);
    });
  });

  approveBtn?.addEventListener('click', () => {
    hidePopover();
    if (toneConf) toneConf.textContent = 'hash approved · stored locally';
  });
  rephraseBtn?.addEventListener('click', () => {
    if (toneConf) toneConf.textContent = 'rewrite copied to clipboard';
    hidePopover();
  });

  // Start with the hostile sample once the demo scrolls into view
  if ('IntersectionObserver' in window) {
    const demoSection = document.getElementById('demo');
    if (demoSection) {
      let started = false;
      const startObs = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting && !started) {
            started = true;
            const firstPill = document.querySelector('.demo-pill[data-sample="hostile"]');
            firstPill?.classList.add('is-active');
            playSample('hostile');
            startObs.disconnect();
          }
        });
      }, { threshold: 0.35 });
      startObs.observe(demoSection);
    }
  } else {
    playSample('hostile');
  }

  /* ---------- Stat counters ---------- */
  const statNums = document.querySelectorAll('.stat-num');
  const animateStat = (el) => {
    const target = parseInt(el.dataset.target || '0', 10);
    if (prefersReducedMotion || target === 0) {
      el.textContent = String(target);
      return;
    }
    const duration = 1100;
    const start = performance.now();
    const tick = (now) => {
      const t = Math.min(1, (now - start) / duration);
      const eased = 1 - Math.pow(1 - t, 3);
      el.textContent = Math.round(target * eased).toString();
      if (t < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  if ('IntersectionObserver' in window && statNums.length) {
    const so = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          animateStat(entry.target);
          so.unobserve(entry.target);
        }
      });
    }, { threshold: 0.4 });
    statNums.forEach((el) => so.observe(el));
  } else {
    statNums.forEach(animateStat);
  }
})();
