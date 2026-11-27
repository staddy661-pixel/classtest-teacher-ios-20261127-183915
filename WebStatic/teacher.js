(() => {
  const app = document.getElementById('app');
  const modalRoot = document.getElementById('modalRoot');
  const toasts = document.getElementById('toasts');

  const state = {
    authed: null,
    tab: 'live', // live | tests | groups | journal | settings
    network: { ips: ['127.0.0.1'], port: 8000 },
    selectedIpIndex: 0,
    tunnelAutoPicked: false,
    tunnelTimer: null,
    groups: [],
    tests: [],
    session: null,
    attempts: [],
    journal: { records: [], groups: [], tests: [] },
    journalFilter: { group: '', test: '', q: '' },
    settings: {
      grading_scale: '10',
      sound_enabled: true,
      default_violation_grade: '2',
      scale_10: [],
      scale_5: [],
    },
    launchForm: {
      group_id: '',
      test_id: '',
      violation_action: 'grade',
      violation_grade: '2',
      require_fullscreen: false,
      block_printscreen: true,
    },
    testSearch: '',
    editingTest: null, // null = список тестов, объект = редактор теста
    sse: null,
  };

  function esc(str) {
    return String(str ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function toast(msg, type = '') {
    const el = document.createElement('div');
    el.className = 'toast ' + type;
    el.textContent = msg;
    toasts.appendChild(el);
    setTimeout(() => el.remove(), 3200);
  }

  async function api(url, opts = {}) {
    const res = await fetch(url, {
      headers: { 'Content-Type': 'application/json' },
      ...opts,
    });
    const data = await res.json().catch(() => ({}));
    if (res.status === 401 && url !== '/api/auth/login') {
      state.authed = false;
      closeSSE();
      render();
      throw new Error('Требуется вход');
    }
    if (!res.ok) throw new Error(data.error || 'Ошибка запроса');
    return data;
  }

  // Звуковой сигнал при нарушении (Web Audio API, без внешних файлов)
  function playAlertSound() {
    if (!state.settings.sound_enabled) return;
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const now = ctx.currentTime;
      [880, 660].forEach((freq, i) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.setValueAtTime(freq, now + i * 0.16);
        gain.gain.setValueAtTime(0.18, now + i * 0.16);
        gain.gain.exponentialRampToValueAtTime(0.001, now + i * 0.16 + 0.15);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(now + i * 0.16);
        osc.stop(now + i * 0.16 + 0.16);
      });
    } catch {}
  }

  function getStudentUrl() {
    const n = state.network;
    if (n.public_url && state.selectedIpIndex === n.ips.length) return n.public_url;
    const ip = n.ips[state.selectedIpIndex] || n.ips[0] || '127.0.0.1';
    return `http://${ip}:${n.port}`;
  }

  // Интернет-ссылка (для сетей, где телефоны не видят ноутбук): как только появилась — выбираем её
  function applyNetwork(net) {
    state.network = net;
    if (net.public_url && !state.tunnelAutoPicked) {
      state.tunnelAutoPicked = true;
      state.selectedIpIndex = net.ips.length;
    }
  }

  function tunnelNote(n) {
    if (n.tunnel_status === 'starting') return 'Запускается интернет-ссылка…';
    if (n.tunnel_status === 'missing') return 'Интернет-ссылка не запущена: рядом с server.py нет cloudflared';
    if (n.tunnel_status === 'failed') return 'Не удалось запустить интернет-ссылку';
    return '';
  }

  function watchTunnel() {
    if (state.tunnelTimer || state.network.tunnel_status !== 'starting') return;
    state.tunnelTimer = setInterval(async () => {
      try {
        applyNetwork(await api('/api/network'));
        if (state.network.tunnel_status !== 'starting') {
          clearInterval(state.tunnelTimer);
          state.tunnelTimer = null;
        }
        if (state.tab === 'live' && state.session) renderTabContent();
      } catch {}
    }, 3000);
  }

  // -------------------------------------------------------------------------
  // SSE в реальном времени
  // -------------------------------------------------------------------------
  function closeSSE() {
    if (state.sse) {
      state.sse.close();
      state.sse = null;
    }
  }

  function connectSSE() {
    closeSSE();
    const es = new EventSource('/api/events/teacher');
    state.sse = es;

    es.addEventListener('session_changed', async () => {
      await loadActiveSession();
      render();
    });

    es.addEventListener('attempt_update', (e) => {
      try {
        const att = JSON.parse(e.data);
        const idx = state.attempts.findIndex((a) => a.id === att.id);
        if (idx >= 0) state.attempts[idx] = att;
        else state.attempts.push(att);
        if (state.tab === 'live') renderTabContent();
      } catch {}
    });

    es.addEventListener('violation_alert', (e) => {
      try {
        const info = JSON.parse(e.data);
        playAlertSound();
        toast(`${info.student_name}: ${info.reason}`, 'error');
        if (state.tab !== 'live') {
          // Обновим индикатор в шапке
          render();
        }
      } catch {}
    });
  }

  // -------------------------------------------------------------------------
  // Загрузка данных
  // -------------------------------------------------------------------------
  async function loadAllData() {
    const [net, grps, tsts, sess, sets] = await Promise.all([
      api('/api/network'),
      api('/api/groups'),
      api('/api/tests'),
      api('/api/session/active'),
      api('/api/settings'),
    ]);
    applyNetwork(net);
    watchTunnel();
    state.groups = grps.groups || [];
    state.tests = tsts.tests || [];
    state.session = sess.session;
    state.attempts = sess.attempts || [];
    state.settings = sets;
    if (!state.launchForm.violation_grade && sets.default_violation_grade) {
      state.launchForm.violation_grade = sets.default_violation_grade;
    } else if (sets.default_violation_grade) {
      state.launchForm.violation_grade = sets.default_violation_grade;
    }
    if (!state.launchForm.group_id && state.groups.length > 0) {
      state.launchForm.group_id = String(state.groups[0].id);
    }
    if (!state.launchForm.test_id && state.tests.length > 0) {
      state.launchForm.test_id = String(state.tests[0].id);
    }
  }

  async function loadActiveSession() {
    const sess = await api('/api/session/active');
    state.session = sess.session;
    state.attempts = sess.attempts || [];
  }

  async function loadGroups() {
    const res = await api('/api/groups');
    state.groups = res.groups || [];
  }

  async function loadTests() {
    const res = await api('/api/tests');
    state.tests = res.tests || [];
  }

  async function loadJournal() {
    const p = new URLSearchParams();
    if (state.journalFilter.group) p.set('group', state.journalFilter.group);
    if (state.journalFilter.test) p.set('test', state.journalFilter.test);
    if (state.journalFilter.q) p.set('q', state.journalFilter.q);
    state.journal = await api('/api/journal?' + p.toString());
  }

  // -------------------------------------------------------------------------
  // Корневой рендер
  // -------------------------------------------------------------------------
  function render() {
    if (state.authed === null) {
      app.innerHTML = '';
      return;
    }
    if (!state.authed) {
      renderLogin();
      return;
    }

    const unackViolations = state.attempts.filter((a) => a.status === 'violated' && !a.alert_dismissed).length;

    app.innerHTML = `
      <header class="topbar">
        <div class="brand">
          <div class="brand-mark">К</div>
          <span>КлассТест</span>
        </div>
        <nav class="nav-tabs">
          <button class="nav-tab ${state.tab === 'live' ? 'active' : ''}" data-tab="live">
            ${state.session ? '<span class="live-dot"></span>' : ''}
            Контрольная
            ${unackViolations > 0 ? `<span class="badge badge-red">${unackViolations}</span>` : ''}
          </button>
          <button class="nav-tab ${state.tab === 'tests' ? 'active' : ''}" data-tab="tests">Тесты</button>
          <button class="nav-tab ${state.tab === 'groups' ? 'active' : ''}" data-tab="groups">Группы</button>
          <button class="nav-tab ${state.tab === 'journal' ? 'active' : ''}" data-tab="journal">Журнал</button>
          <button class="nav-tab ${state.tab === 'settings' ? 'active' : ''}" data-tab="settings">Настройки</button>
        </nav>
        <button id="logoutBtn" class="btn btn-ghost btn-sm">Выйти</button>
      </header>
      <main id="tabContent" class="container"></main>
    `;

    app.querySelectorAll('.nav-tab').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const nextTab = btn.dataset.tab;
        if (state.tab === 'tests' && state.editingTest && nextTab !== 'tests') {
          if (!confirm('Выйти из редактора? Несохранённые изменения будут потеряны.')) return;
          state.editingTest = null;
        }
        state.tab = nextTab;
        if (nextTab === 'journal') await loadJournal();
        if (nextTab === 'groups') await loadGroups();
        if (nextTab === 'tests') await loadTests();
        if (nextTab === 'live') await loadActiveSession();
        render();
      });
    });

    document.getElementById('logoutBtn').addEventListener('click', async () => {
      await api('/api/auth/logout', { method: 'POST' });
      closeSSE();
      state.authed = false;
      render();
    });

    renderTabContent();
  }

  function renderLogin() {
    app.innerHTML = `
      <div class="auth-wrap">
        <div class="card auth-card">
          <h1 class="auth-title">
            <div class="brand-mark">К</div>
            КлассТест
          </h1>
          <form id="loginForm">
            <div class="field">
              <label class="label">Пароль</label>
              <input id="loginPassword" class="input" type="password" placeholder="••••" required autofocus>
            </div>
            <div id="loginError" style="color:var(--danger);font-size:13px;margin-bottom:12px" class="hidden"></div>
            <button type="submit" class="btn btn-primary btn-lg" style="width:100%">Войти</button>
          </form>
        </div>
      </div>`;

    document.getElementById('loginForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const pw = document.getElementById('loginPassword').value;
      const errEl = document.getElementById('loginError');
      errEl.classList.add('hidden');
      try {
        await api('/api/auth/login', { method: 'POST', body: JSON.stringify({ password: pw }) });
        state.authed = true;
        await loadAllData();
        connectSSE();
        render();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.classList.remove('hidden');
      }
    });
  }

  function renderTabContent() {
    const root = document.getElementById('tabContent');
    if (!root) return;
    if (state.tab === 'live') renderLiveTab(root);
    else if (state.tab === 'tests') renderTestsTab(root);
    else if (state.tab === 'groups') renderGroupsTab(root);
    else if (state.tab === 'journal') renderJournalTab(root);
    else if (state.tab === 'settings') renderSettingsTab(root);
  }

  // =========================================================================
  // ВКЛАДКА 1: КОНТРОЛЬНАЯ (ЗАПУСК И ЖИВОЙ МОНИТОРИНГ)
  // =========================================================================
  function renderLiveTab(root) {
    if (!state.session) {
      const f = state.launchForm;
      root.innerHTML = `
        <div class="card launch-card">
          <h2>Запуск контрольной</h2>
          <div class="field">
            <div class="row-between" style="margin-bottom:5px">
              <label class="label" style="margin:0">Группа</label>
              <button type="button" id="quickAddGroup" class="btn btn-ghost btn-sm" style="padding:2px 6px">+ Группа</button>
            </div>
            <select id="launchGroup" class="select">
              ${
                state.groups.length === 0
                  ? '<option value="">Нет групп</option>'
                  : state.groups
                      .map((g) => `<option value="${g.id}" ${String(g.id) === String(f.group_id) ? 'selected' : ''}>${esc(g.name)}${g.students.length ? ` (${g.students.length} чел.)` : ''}</option>`)
                      .join('')
              }
            </select>
          </div>

          <div class="field">
            <div class="row-between" style="margin-bottom:5px">
              <label class="label" style="margin:0">Тест</label>
              <button type="button" id="quickAddTest" class="btn btn-ghost btn-sm" style="padding:2px 6px">+ Тест</button>
            </div>
            <select id="launchTest" class="select">
              ${
                state.tests.length === 0
                  ? '<option value="">Сначала создайте тест</option>'
                  : state.tests
                      .map((t) => `<option value="${t.id}" ${String(t.id) === String(f.test_id) ? 'selected' : ''}>${esc(t.title)} (${t.questions_count} вопр.)</option>`)
                      .join('')
              }
            </select>
          </div>

          <div class="field">
            <label class="label">При выходе или сворачивании</label>
            <div class="seg-group">
              <button type="button" class="seg-btn ${f.violation_action === 'grade' ? 'active' : ''}" data-va="grade">
                Поставить оценку
              </button>
              <button type="button" class="seg-btn ${f.violation_action === 'no_grade' ? 'active' : ''}" data-va="no_grade">
                Завершить без оценки
              </button>
            </div>
          </div>

          <div id="violGradeWrap" class="field ${f.violation_action === 'grade' ? '' : 'hidden'}">
            <label class="label">Оценка за нарушение</label>
            <input id="violGradeInput" class="input" type="text" value="${esc(f.violation_grade)}" style="max-width:140px" placeholder="2">
          </div>

          <div class="field" style="display:flex;flex-direction:column;gap:8px;margin-top:16px">
            <label class="check-row">
              <input type="checkbox" id="chkFullscreen" ${f.require_fullscreen ? 'checked' : ''}>
              <span>Требовать полноэкранный режим</span>
            </label>
            <label class="check-row">
              <input type="checkbox" id="chkPrintscreen" ${f.block_printscreen ? 'checked' : ''}>
              <span>Завершать при нажатии PrintScreen</span>
            </label>
          </div>

          <button id="startSessionBtn" class="btn btn-primary btn-lg" style="width:100%;margin-top:10px" ${
            state.groups.length === 0 || state.tests.length === 0 ? 'disabled' : ''
          }>Запустить контрольную</button>
        </div>`;

      document.getElementById('launchGroup').addEventListener('change', (e) => { f.group_id = e.target.value; });
      document.getElementById('launchTest').addEventListener('change', (e) => { f.test_id = e.target.value; });
      root.querySelectorAll('[data-va]').forEach((b) => {
        b.addEventListener('click', () => {
          f.violation_action = b.dataset.va;
          renderTabContent();
        });
      });
      const vgi = document.getElementById('violGradeInput');
      if (vgi) vgi.addEventListener('input', (e) => { f.violation_grade = e.target.value; });
      document.getElementById('chkFullscreen').addEventListener('change', (e) => { f.require_fullscreen = e.target.checked; });
      document.getElementById('chkPrintscreen').addEventListener('change', (e) => { f.block_printscreen = e.target.checked; });

      document.getElementById('quickAddGroup').addEventListener('click', () => openGroupModal(null));
      document.getElementById('quickAddTest').addEventListener('click', () => {
        state.tab = 'tests';
        startNewTestEditor();
        render();
      });

      document.getElementById('startSessionBtn').addEventListener('click', async () => {
        try {
          await api('/api/session/start', {
            method: 'POST',
            body: JSON.stringify({
              group_id: Number(document.getElementById('launchGroup').value),
              test_id: Number(document.getElementById('launchTest').value),
              violation_action: f.violation_action,
              violation_grade: f.violation_grade,
              require_fullscreen: f.require_fullscreen,
              block_printscreen: f.block_printscreen,
            }),
          });
          await loadActiveSession();
          render();
        } catch (err) {
          toast(err.message, 'error');
        }
      });
      return;
    }

    // Активная контрольная
    const s = state.session;
    const total = state.attempts.length;
    const inProg = state.attempts.filter((a) => a.status === 'in_progress').length;
    const submitted = state.attempts.filter((a) => a.status === 'submitted').length;
    const violated = state.attempts.filter((a) => a.status === 'violated').length;
    const alerts = state.attempts.filter((a) => a.status === 'violated' && !a.alert_dismissed);

    const url = getStudentUrl();
    const qrSrc = `/api/qr?text=${encodeURIComponent(url)}`;

    // Сортировка: сначала нарушения, потом в процессе, потом сдавшие
    const orderMap = { violated: 0, in_progress: 1, submitted: 2 };
    const sorted = [...state.attempts].sort((a, b) => {
      const d = (orderMap[a.status] ?? 9) - (orderMap[b.status] ?? 9);
      return d !== 0 ? d : a.student_name.localeCompare(b.student_name, 'ru');
    });

    root.innerHTML = `
      <div class="card live-header">
        <div>
          <div class="live-meta">
            <span class="badge badge-blue">${esc(s.group_name)}</span>
            <h2 class="live-title">${esc(s.test_title)}</h2>
            ${s.time_limit > 0 ? `<span class="badge badge-gray">${s.time_limit} мин</span>` : ''}
            <span class="badge badge-gray">${
              s.violation_action === 'grade' ? `Штраф: ${esc(s.violation_grade)}` : 'Без авто-оценки'
            }</span>
          </div>
        </div>
        <div class="row">
          <div class="stats-strip">
            <span class="stat-pill">Всего<strong>${total}</strong></span>
            <span class="stat-pill">Решают<strong>${inProg}</strong></span>
            <span class="stat-pill success">Сдали<strong>${submitted}</strong></span>
            <span class="stat-pill danger">Нарушения<strong>${violated}</strong></span>
          </div>
          <button id="stopSessionBtn" class="btn btn-danger btn-sm">Завершить для всех</button>
        </div>
      </div>

      <div class="card connect-bar">
        <div class="row" style="gap:16px">
          <div id="qrThumb" class="qr-thumb" title="Открыть на весь экран">
            <img src="${qrSrc}" alt="QR">
          </div>
          <div>
            <div style="font-size:12.5px;color:var(--text-muted);margin-bottom:3px">Адрес для учеников</div>
            <div class="lan-url">${esc(url)}</div>
            ${tunnelNote(state.network) ? `<div style="font-size:12px;color:var(--text-muted);margin-top:2px">${esc(tunnelNote(state.network))}</div>` : ''}
            <div class="row" style="margin-top:8px;gap:8px">
              <button id="copyUrlBtn" class="btn btn-sm">Копировать</button>
              <button id="bigQrBtn" class="btn btn-sm">Крупный QR</button>
              ${
                state.network.ips.length > 1 || state.network.public_url
                  ? `<select id="ipSelect" class="select" style="width:auto;padding:5px 10px;font-size:13px">
                      ${state.network.ips
                        .map((ip, i) => `<option value="${i}" ${i === state.selectedIpIndex ? 'selected' : ''}>${esc(ip)}</option>`)
                        .join('')}
                      ${
                        state.network.public_url
                          ? `<option value="${state.network.ips.length}" ${state.selectedIpIndex === state.network.ips.length ? 'selected' : ''}>🌐 Через интернет</option>`
                          : ''
                      }
                    </select>`
                  : ''
              }
            </div>
          </div>
        </div>
        <button id="toggleSoundBtn" class="btn btn-sm">
          Звук: ${state.settings.sound_enabled ? 'Вкл' : 'Выкл'}
        </button>
      </div>

      ${
        alerts.length > 0
          ? `<div class="alert-stack">
              ${alerts
                .map(
                  (a) => `
                  <div class="alert-item">
                    <div class="alert-item-text">
                      <strong>${esc(a.student_name)}</strong> — ${esc(a.violation_reason)}
                      <span style="color:var(--text-muted);margin-left:6px">${esc((a.violation_time || '').slice(11, 19))}</span>
                      ${a.grade && a.grade !== '—' ? `<span class="badge badge-red" style="margin-left:8px">Оценка: ${esc(a.grade)}</span>` : ''}
                    </div>
                    <div class="row" style="gap:6px">
                      <button class="btn btn-sm btn-primary" data-unblock="${a.id}">Разблокировать</button>
                      <button class="btn btn-sm" data-dismiss="${a.id}">Скрыть</button>
                    </div>
                  </div>`
                )
                .join('')}
            </div>`
          : ''
      }

      ${
        sorted.length === 0
          ? `<div class="card empty-state">Ожидание подключения учеников</div>`
          : `<div class="students-grid">
              ${sorted
                .map((a) => {
                  const pct = a.total_questions > 0 ? Math.round((a.answered_count / a.total_questions) * 100) : 0;
                  const statusBadge =
                    a.status === 'violated'
                      ? '<span class="badge badge-red">Нарушение</span>'
                      : a.status === 'submitted'
                      ? '<span class="badge badge-green">Сдал</span>'
                      : '<span class="badge badge-blue">Решает</span>';
                  return `
                    <div class="student-card ${a.status}" data-attempt-id="${a.id}">
                      <div class="row-between">
                        <div class="student-name">${esc(a.student_name)}</div>
                        ${
                          a.status !== 'in_progress' && a.grade
                            ? `<div class="grade-box ${a.status === 'violated' ? 'violated' : ''}">${esc(a.grade)}</div>`
                            : statusBadge
                        }
                      </div>
                      <div class="row-between" style="font-size:12.5px;color:var(--text-muted)">
                        <span>${
                          a.status === 'violated'
                            ? esc(a.violation_reason)
                            : a.status === 'submitted'
                            ? `Баллы: ${a.score}/${a.max_score} (${a.percent}%)`
                            : `Ответов: ${a.answered_count} из ${a.total_questions}`
                        }</span>
                        ${a.status !== 'in_progress' ? statusBadge : ''}
                      </div>
                      <div class="progress-bar"><div class="progress-fill" style="width:${pct}%"></div></div>
                      ${
                        a.status === 'violated'
                          ? `<div class="row" style="gap:6px;margin-top:2px">
                              <button class="btn btn-sm btn-primary" style="flex:1" data-unblock="${a.id}">Разблокировать</button>
                            </div>`
                          : ''
                      }
                    </div>`;
                })
                .join('')}
            </div>`
      }
    `;

    document.getElementById('stopSessionBtn').addEventListener('click', async () => {
      if (!confirm('Завершить контрольную для всех учеников?')) return;
      await api('/api/session/stop', { method: 'POST' });
      await loadActiveSession();
      render();
      toast('Контрольная завершена', 'success');
    });

    document.getElementById('copyUrlBtn').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(url);
        toast('Адрес скопирован', 'success');
      } catch {
        toast(url);
      }
    });

    const openQr = () => {
      modalRoot.innerHTML = `
        <div class="modal-backdrop" id="qrBackdrop">
          <div class="qr-modal-box">
            <img src="${qrSrc}" alt="QR">
            <div class="qr-modal-url">${esc(url)}</div>
            <button id="closeQrBtn" class="btn" style="margin-top:18px">Закрыть</button>
          </div>
        </div>`;
      document.getElementById('closeQrBtn').addEventListener('click', () => (modalRoot.innerHTML = ''));
      document.getElementById('qrBackdrop').addEventListener('click', (e) => {
        if (e.target.id === 'qrBackdrop') modalRoot.innerHTML = '';
      });
    };
    document.getElementById('qrThumb').addEventListener('click', openQr);
    document.getElementById('bigQrBtn').addEventListener('click', openQr);

    const ipSel = document.getElementById('ipSelect');
    if (ipSel) {
      ipSel.addEventListener('change', (e) => {
        state.selectedIpIndex = Number(e.target.value);
        renderTabContent();
      });
    }

    document.getElementById('toggleSoundBtn').addEventListener('click', async () => {
      state.settings.sound_enabled = !state.settings.sound_enabled;
      await api('/api/settings', {
        method: 'POST',
        body: JSON.stringify({ sound_enabled: state.settings.sound_enabled }),
      });
      renderTabContent();
    });

    root.querySelectorAll('[data-unblock]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await api(`/api/attempts/${btn.dataset.unblock}/unblock`, { method: 'POST' });
        toast('Ученик разблокирован', 'success');
      });
    });

    root.querySelectorAll('[data-dismiss]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await api(`/api/attempts/${btn.dataset.dismiss}/dismiss`, { method: 'POST' });
      });
    });

    root.querySelectorAll('.student-card').forEach((card) => {
      card.addEventListener('click', () => openAttemptDetails(Number(card.dataset.attemptId)));
    });
  }

  // =========================================================================
  // ВКЛАДКА 2: ТЕСТЫ И УДОБНЫЙ КОНСТРУКТОР ТЕСТОВ
  // =========================================================================
  function createEmptyQuestion(type = 'single') {
    const base = {
      id: 'q_' + Math.random().toString(36).slice(2, 9),
      type,
      text: '',
      points: 1,
    };
    if (type === 'text') {
      base.acceptedText = '';
    } else {
      base.options = ['', ''];
      base.correct = [0];
    }
    return base;
  }

  function startNewTestEditor() {
    state.editingTest = {
      id: null,
      title: '',
      time_limit: 15,
      grading_scale: 'default',
      shuffle_questions: false,
      shuffle_options: false,
      questions: [createEmptyQuestion('single')],
    };
  }

  function renderTestsTab(root) {
    if (state.editingTest) {
      renderTestEditor(root);
      return;
    }

    const q = state.testSearch.trim().toLowerCase();
    const filtered = state.tests.filter((t) => !q || t.title.toLowerCase().includes(q));
    const scaleNames = { default: 'По умолчанию', '10': '10-балльная', '5': '5-балльная', points: 'Баллы' };

    root.innerHTML = `
      <div class="row-between" style="margin-bottom:16px">
        <input id="testSearchInput" class="input" type="search" placeholder="Поиск теста..." value="${esc(state.testSearch)}" style="max-width:300px">
        <button id="newTestBtn" class="btn btn-primary">+ Создать тест</button>
      </div>

      ${
        filtered.length === 0
          ? `<div class="card empty-state">
              <div style="margin-bottom:12px">Тестов пока нет</div>
              <button id="emptyNewTestBtn" class="btn btn-primary">Создать первый тест</button>
            </div>`
          : `<div class="grid-2">
              ${filtered
                .map(
                  (t) => `
                  <div class="card card-pad" style="display:flex;flex-direction:column;justify-content:space-between;gap:14px">
                    <div>
                      <div style="font-weight:700;font-size:16px;margin-bottom:6px">${esc(t.title)}</div>
                      <div class="row" style="gap:8px;font-size:13px;color:var(--text-muted)">
                        <span>Вопросов: ${t.questions_count}</span>
                        <span>·</span>
                        <span>${t.time_limit > 0 ? `${t.time_limit} мин` : 'Без таймера'}</span>
                        <span>·</span>
                        <span>${scaleNames[t.grading_scale] || t.grading_scale}</span>
                      </div>
                    </div>
                    <div class="row" style="gap:8px">
                      <button class="btn btn-primary btn-sm" data-launch="${t.id}">Запустить</button>
                      <button class="btn btn-sm" data-edit="${t.id}">Редактировать</button>
                      <button class="btn btn-sm" data-dup="${t.id}">Копия</button>
                      <button class="btn btn-ghost btn-sm" style="margin-left:auto;color:var(--danger)" data-del="${t.id}">Удалить</button>
                    </div>
                  </div>`
                )
                .join('')}
            </div>`
      }
    `;

    const si = document.getElementById('testSearchInput');
    si.addEventListener('input', (e) => {
      state.testSearch = e.target.value;
      renderTabContent();
      const again = document.getElementById('testSearchInput');
      if (again) {
        again.focus();
        again.setSelectionRange(again.value.length, again.value.length);
      }
    });

    const openNew = () => {
      startNewTestEditor();
      renderTabContent();
      const titleEl = document.getElementById('edTitle');
      if (titleEl) titleEl.focus();
    };
    document.getElementById('newTestBtn').addEventListener('click', openNew);
    const eb = document.getElementById('emptyNewTestBtn');
    if (eb) eb.addEventListener('click', openNew);

    root.querySelectorAll('[data-launch]').forEach((b) => {
      b.addEventListener('click', () => {
        state.launchForm.test_id = b.dataset.launch;
        state.tab = 'live';
        render();
      });
    });

    root.querySelectorAll('[data-edit]').forEach((b) => {
      b.addEventListener('click', () => {
        const found = state.tests.find((t) => String(t.id) === b.dataset.edit);
        if (!found) return;
        state.editingTest = JSON.parse(JSON.stringify(found));
        renderTabContent();
      });
    });

    root.querySelectorAll('[data-dup]').forEach((b) => {
      b.addEventListener('click', async () => {
        await api(`/api/tests/${b.dataset.dup}/duplicate`, { method: 'POST' });
        await loadTests();
        renderTabContent();
        toast('Копия создана', 'success');
      });
    });

    root.querySelectorAll('[data-del]').forEach((b) => {
      b.addEventListener('click', async () => {
        if (!confirm('Удалить этот тест?')) return;
        await api(`/api/tests/${b.dataset.del}`, { method: 'DELETE' });
        await loadTests();
        renderTabContent();
        toast('Тест удалён');
      });
    });
  }

  function renderTestEditor(root) {
    const t = state.editingTest;

    root.innerHTML = `
      <div class="editor-topbar">
        <button id="edBackBtn" class="btn btn-sm">← Назад</button>
        <input id="edTitle" class="title-input" type="text" placeholder="Название теста..." value="${esc(t.title)}">
        <button id="edSaveBtn" class="btn btn-primary">Сохранить</button>
      </div>

      <div class="card editor-settings">
        <div class="row" style="gap:6px">
          <span class="label" style="margin:0">Время (мин):</span>
          <input id="edTime" class="input" type="number" min="0" max="300" value="${t.time_limit}" style="width:82px;padding:6px 8px">
        </div>
        <div class="row" style="gap:6px">
          <span class="label" style="margin:0">Шкала:</span>
          <select id="edScale" class="select" style="width:auto;padding:6px 10px">
            <option value="default" ${t.grading_scale === 'default' ? 'selected' : ''}>По умолчанию</option>
            <option value="10" ${t.grading_scale === '10' ? 'selected' : ''}>10-балльная</option>
            <option value="5" ${t.grading_scale === '5' ? 'selected' : ''}>5-балльная</option>
            <option value="points" ${t.grading_scale === 'points' ? 'selected' : ''}>Только баллы</option>
          </select>
        </div>
        <label class="check-row">
          <input type="checkbox" id="edShuffleQ" ${t.shuffle_questions ? 'checked' : ''}>
          <span>Перемешать вопросы</span>
        </label>
        <label class="check-row">
          <input type="checkbox" id="edShuffleO" ${t.shuffle_options ? 'checked' : ''}>
          <span>Перемешать варианты</span>
        </label>
      </div>

      <div id="questionsList">
        ${t.questions.map((q, qi) => renderQuestionEditorCard(q, qi, t.questions.length)).join('')}
      </div>

      <div class="add-q-bar">
        <button class="btn btn-primary" data-add-q="single">+ Один ответ</button>
        <button class="btn" data-add-q="multiple">+ Несколько ответов</button>
        <button class="btn" data-add-q="text">+ Текстовый ответ</button>
      </div>
    `;

    // Привязка верхних полей (без перерисовки DOM)
    document.getElementById('edBackBtn').addEventListener('click', () => {
      state.editingTest = null;
      renderTabContent();
    });
    document.getElementById('edTitle').addEventListener('input', (e) => { t.title = e.target.value; });
    document.getElementById('edTime').addEventListener('input', (e) => { t.time_limit = Math.max(0, Number(e.target.value) || 0); });
    document.getElementById('edScale').addEventListener('change', (e) => { t.grading_scale = e.target.value; });
    document.getElementById('edShuffleQ').addEventListener('change', (e) => { t.shuffle_questions = e.target.checked; });
    document.getElementById('edShuffleO').addEventListener('change', (e) => { t.shuffle_options = e.target.checked; });

    document.getElementById('edSaveBtn').addEventListener('click', saveEditingTest);

    // События по карточкам вопросов
    t.questions.forEach((q, qi) => {
      const card = root.querySelector(`.q-card[data-qi="${qi}"]`);
      if (!card) return;

      card.querySelectorAll('[data-qtype]').forEach((btn) => {
        btn.addEventListener('click', () => {
          const nextType = btn.dataset.qtype;
          if (q.type === nextType) return;
          q.type = nextType;
          if (nextType === 'text') {
            q.acceptedText = q.acceptedText || '';
          } else {
            if (!Array.isArray(q.options) || q.options.length < 2) q.options = ['', ''];
            if (!Array.isArray(q.correct) || q.correct.length === 0) q.correct = [0];
            if (nextType === 'single') q.correct = [q.correct[0]];
          }
          renderTabContent();
        });
      });

      card.querySelector('[data-q-points]').addEventListener('input', (e) => {
        q.points = Number(e.target.value) || 1;
      });

      card.querySelector('[data-q-text]').addEventListener('input', (e) => {
        q.text = e.target.value;
        card.classList.remove('error-highlight');
      });

      const moveUp = card.querySelector('[data-q-up]');
      if (moveUp) {
        moveUp.addEventListener('click', () => {
          if (qi === 0) return;
          [t.questions[qi - 1], t.questions[qi]] = [t.questions[qi], t.questions[qi - 1]];
          renderTabContent();
        });
      }
      const moveDown = card.querySelector('[data-q-down]');
      if (moveDown) {
        moveDown.addEventListener('click', () => {
          if (qi >= t.questions.length - 1) return;
          [t.questions[qi + 1], t.questions[qi]] = [t.questions[qi], t.questions[qi + 1]];
          renderTabContent();
        });
      }
      card.querySelector('[data-q-copy]').addEventListener('click', () => {
        const clone = JSON.parse(JSON.stringify(q));
        clone.id = 'q_' + Math.random().toString(36).slice(2, 9);
        t.questions.splice(qi + 1, 0, clone);
        renderTabContent();
      });
      card.querySelector('[data-q-del]').addEventListener('click', () => {
        if (t.questions.length === 1) {
          toast('В тесте должен быть хотя бы один вопрос', 'error');
          return;
        }
        t.questions.splice(qi, 1);
        renderTabContent();
      });

      if (q.type === 'text') {
        card.querySelector('[data-q-accepted]').addEventListener('input', (e) => {
          q.acceptedText = e.target.value;
          card.classList.remove('error-highlight');
        });
      } else {
        card.querySelectorAll('[data-opt-pick]').forEach((inp) => {
          inp.addEventListener('change', () => {
            const oi = Number(inp.dataset.optPick);
            if (q.type === 'single') {
              q.correct = [oi];
            } else {
              const set = new Set(q.correct || []);
              if (inp.checked) set.add(oi);
              else set.delete(oi);
              q.correct = [...set].sort((a, b) => a - b);
            }
            renderTabContent();
          });
        });

        card.querySelectorAll('[data-opt-text]').forEach((inp) => {
          const oi = Number(inp.dataset.optText);
          inp.addEventListener('input', (e) => {
            q.options[oi] = e.target.value;
            card.classList.remove('error-highlight');
          });
          inp.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              q.options.splice(oi + 1, 0, '');
              q.correct = (q.correct || []).map((c) => (c > oi ? c + 1 : c));
              renderTabContent();
              const nextInp = document.querySelector(`.q-card[data-qi="${qi}"] [data-opt-text="${oi + 1}"]`);
              if (nextInp) nextInp.focus();
            }
          });
        });

        card.querySelectorAll('[data-opt-del]').forEach((btn) => {
          btn.addEventListener('click', () => {
            const oi = Number(btn.dataset.optDel);
            if (q.options.length <= 2) {
              toast('Нужно минимум 2 варианта', 'error');
              return;
            }
            q.options.splice(oi, 1);
            q.correct = (q.correct || [])
              .filter((c) => c !== oi)
              .map((c) => (c > oi ? c - 1 : c));
            if (q.correct.length === 0) q.correct = [0];
            renderTabContent();
          });
        });

        card.querySelector('[data-add-opt]').addEventListener('click', () => {
          q.options.push('');
          renderTabContent();
          const newInp = document.querySelector(`.q-card[data-qi="${qi}"] [data-opt-text="${q.options.length - 1}"]`);
          if (newInp) newInp.focus();
        });
      }
    });

    root.querySelectorAll('[data-add-q]').forEach((btn) => {
      btn.addEventListener('click', () => {
        t.questions.push(createEmptyQuestion(btn.dataset.addQ));
        renderTabContent();
        const newIdx = t.questions.length - 1;
        const area = document.querySelector(`.q-card[data-qi="${newIdx}"] [data-q-text]`);
        if (area) {
          area.scrollIntoView({ behavior: 'smooth', block: 'center' });
          area.focus();
        }
      });
    });
  }

  function renderQuestionEditorCard(q, qi, total) {
    const corrSet = new Set(q.correct || []);
    return `
      <div class="q-card" data-qi="${qi}">
        <div class="q-head">
          <div class="row" style="gap:10px">
            <span class="q-num">№${qi + 1}</span>
            <div class="type-pills">
              <button type="button" class="type-pill ${q.type === 'single' ? 'active' : ''}" data-qtype="single">Один ответ</button>
              <button type="button" class="type-pill ${q.type === 'multiple' ? 'active' : ''}" data-qtype="multiple">Несколько</button>
              <button type="button" class="type-pill ${q.type === 'text' ? 'active' : ''}" data-qtype="text">Текст</button>
            </div>
          </div>
          <div class="row" style="gap:6px">
            <span style="font-size:12.5px;color:var(--text-muted)">Балл:</span>
            <input type="number" class="input" data-q-points min="0.5" step="0.5" value="${q.points || 1}" style="width:64px;padding:4px 8px">
            <button type="button" class="btn btn-icon btn-sm" data-q-up ${qi === 0 ? 'disabled' : ''} title="Вверх">↑</button>
            <button type="button" class="btn btn-icon btn-sm" data-q-down ${qi === total - 1 ? 'disabled' : ''} title="Вниз">↓</button>
            <button type="button" class="btn btn-sm" data-q-copy title="Дублировать">Копия</button>
            <button type="button" class="btn btn-ghost btn-sm" style="color:var(--danger)" data-q-del title="Удалить">×</button>
          </div>
        </div>

        <div class="field">
          <textarea class="textarea" data-q-text rows="2" placeholder="Текст вопроса...">${esc(q.text)}</textarea>
        </div>

        ${
          q.type === 'text'
            ? `<div class="field" style="margin-bottom:0">
                <label class="label">Правильный ответ (можно несколько через запятую)</label>
                <input class="input" type="text" data-q-accepted value="${esc(q.acceptedText || '')}" placeholder="Например: 42, сорок два">
              </div>`
            : `<div>
                ${(q.options || [])
                  .map((opt, oi) => {
                    const isC = corrSet.has(oi);
                    return `
                      <div class="opt-row ${isC ? 'is-correct' : ''}">
                        <input
                          class="opt-pick"
                          type="${q.type === 'single' ? 'radio' : 'checkbox'}"
                          name="corr_${qi}"
                          data-opt-pick="${oi}"
                          ${isC ? 'checked' : ''}
                          title="Отметить как правильный"
                        >
                        <input
                          class="opt-input"
                          type="text"
                          data-opt-text="${oi}"
                          value="${esc(opt)}"
                          placeholder="Вариант ${oi + 1} (Enter — добавить следующий)"
                        >
                        <button type="button" class="btn btn-ghost btn-sm" data-opt-del="${oi}" title="Удалить вариант">×</button>
                      </div>`;
                  })
                  .join('')}
                <button type="button" class="btn btn-sm" data-add-opt style="margin-top:4px">+ Вариант ответа</button>
              </div>`
        }
      </div>`;
  }

  async function saveEditingTest() {
    const t = state.editingTest;
    if (!t) return;
    if (!t.title.trim()) {
      toast('Введите название теста', 'error');
      document.getElementById('edTitle')?.focus();
      return;
    }

    for (let i = 0; i < t.questions.length; i++) {
      const q = t.questions[i];
      const highlight = (msg) => {
        toast(`Вопрос №${i + 1}: ${msg}`, 'error');
        const card = document.querySelector(`.q-card[data-qi="${i}"]`);
        if (card) {
          card.classList.add('error-highlight');
          card.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      };
      if (!q.text.trim()) return highlight('введите текст вопроса');
      if (q.type === 'text') {
        if (!(q.acceptedText || '').trim()) return highlight('укажите правильный ответ');
      } else {
        if (!q.options || q.options.length < 2 || q.options.some((o) => !o.trim())) {
          return highlight('заполните все варианты ответа');
        }
        if (!q.correct || q.correct.length === 0) {
          return highlight('отметьте правильный ответ');
        }
      }
    }

    try {
      if (t.id) {
        await api(`/api/tests/${t.id}`, { method: 'PUT', body: JSON.stringify(t) });
      } else {
        const res = await api('/api/tests', { method: 'POST', body: JSON.stringify(t) });
        t.id = res.id;
      }
      await loadTests();
      state.editingTest = null;
      renderTabContent();
      toast('Тест сохранён', 'success');
    } catch (err) {
      toast(err.message, 'error');
    }
  }

  // Горячая клавиша Ctrl+S в редакторе тестов
  window.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && state.tab === 'tests' && state.editingTest) {
      e.preventDefault();
      saveEditingTest();
    }
  });

  // =========================================================================
  // ВКЛАДКА 3: ГРУППЫ
  // =========================================================================
  function renderGroupsTab(root) {
    root.innerHTML = `
      <div class="row-between" style="margin-bottom:16px">
        <div style="font-weight:600;font-size:16px">Группы (${state.groups.length})</div>
        <button id="addGroupBtn" class="btn btn-primary">+ Новая группа</button>
      </div>
      ${
        state.groups.length === 0
          ? `<div class="card empty-state">Создайте первую группу, например Т-691</div>`
          : `<div class="grid-3">
              ${state.groups
                .map(
                  (g) => `
                  <div class="card card-pad" style="display:flex;flex-direction:column;gap:12px">
                    <div class="row-between">
                      <strong style="font-size:17px">${esc(g.name)}</strong>
                      <span class="badge badge-gray">Работ: ${g.sessions_count}</span>
                    </div>
                    <div style="font-size:13px;color:var(--text-muted)">
                      ${
                        g.students.length > 0
                          ? `Список: ${g.students.length} чел.`
                          : 'Свободный ввод фамилии'
                      }
                    </div>
                    <div class="row" style="gap:6px;margin-top:auto">
                      <button class="btn btn-sm" data-grp-journal="${esc(g.name)}">Журнал</button>
                      <button class="btn btn-sm" data-grp-edit="${g.id}">Изменить</button>
                      <button class="btn btn-ghost btn-sm" style="margin-left:auto;color:var(--danger)" data-grp-del="${g.id}">Удалить</button>
                    </div>
                  </div>`
                )
                .join('')}
            </div>`
      }
    `;

    document.getElementById('addGroupBtn').addEventListener('click', () => openGroupModal(null));
    root.querySelectorAll('[data-grp-journal]').forEach((b) => {
      b.addEventListener('click', async () => {
        state.journalFilter.group = b.dataset.grpJournal;
        state.tab = 'journal';
        await loadJournal();
        render();
      });
    });
    root.querySelectorAll('[data-grp-edit]').forEach((b) => {
      b.addEventListener('click', () => {
        const g = state.groups.find((x) => String(x.id) === b.dataset.grpEdit);
        if (g) openGroupModal(g);
      });
    });
    root.querySelectorAll('[data-grp-del]').forEach((b) => {
      b.addEventListener('click', async () => {
        if (!confirm('Удалить группу? Оценки в журнале сохранятся.')) return;
        await api(`/api/groups/${b.dataset.grpDel}`, { method: 'DELETE' });
        await loadGroups();
        renderTabContent();
        toast('Группа удалена');
      });
    });
  }

  function openGroupModal(group) {
    modalRoot.innerHTML = `
      <div class="modal-backdrop" id="grpBackdrop">
        <div class="modal">
          <div class="modal-head">
            <h3>${group ? 'Редактировать группу' : 'Новая группа'}</h3>
            <button class="btn btn-ghost btn-sm" id="closeGrpModal">×</button>
          </div>
          <form id="grpForm">
            <div class="modal-body">
              <div class="field">
                <label class="label">Название группы</label>
                <input id="grpName" class="input" type="text" placeholder="Т-691" value="${esc(group ? group.name : '')}" required autofocus>
              </div>
              <div class="field" style="margin-bottom:0">
                <label class="label">Список учеников (необязательно, по одному в строке)</label>
                <textarea id="grpStudents" class="textarea" rows="8" placeholder="Иванов Иван&#10;Петров Пётр">${esc(
                  group ? (group.students || []).join('\n') : ''
                )}</textarea>
              </div>
            </div>
            <div class="modal-foot">
              <button type="button" class="btn" id="cancelGrpModal">Отмена</button>
              <button type="submit" class="btn btn-primary">Сохранить</button>
            </div>
          </form>
        </div>
      </div>`;

    const close = () => (modalRoot.innerHTML = '');
    document.getElementById('closeGrpModal').addEventListener('click', close);
    document.getElementById('cancelGrpModal').addEventListener('click', close);
    document.getElementById('grpBackdrop').addEventListener('click', (e) => {
      if (e.target.id === 'grpBackdrop') close();
    });

    document.getElementById('grpForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const name = document.getElementById('grpName').value.trim();
      const students = document
        .getElementById('grpStudents')
        .value.split('\n')
        .map((s) => s.trim())
        .filter(Boolean);
      try {
        if (group) {
          await api(`/api/groups/${group.id}`, {
            method: 'PUT',
            body: JSON.stringify({ name, students }),
          });
        } else {
          const res = await api('/api/groups', {
            method: 'POST',
            body: JSON.stringify({ name, students }),
          });
          state.launchForm.group_id = String(res.id);
        }
        await loadGroups();
        close();
        renderTabContent();
        toast('Группа сохранена', 'success');
      } catch (err) {
        toast(err.message, 'error');
      }
    });
  }

  // =========================================================================
  // ВКЛАДКА 4: ЖУРНАЛ ОЦЕНОК
  // =========================================================================
  function renderJournalTab(root) {
    const f = state.journalFilter;
    const exportParams = new URLSearchParams();
    if (f.group) exportParams.set('group', f.group);
    if (f.test) exportParams.set('test', f.test);

    root.innerHTML = `
      <div class="row-between" style="margin-bottom:14px">
        <div class="row" style="gap:8px;flex:1">
          <select id="jfGroup" class="select" style="width:auto;min-width:140px">
            <option value="">Все группы</option>
            ${state.journal.groups
              .map((g) => `<option value="${esc(g)}" ${f.group === g ? 'selected' : ''}>${esc(g)}</option>`)
              .join('')}
          </select>
          <select id="jfTest" class="select" style="width:auto;min-width:180px">
            <option value="">Все тесты</option>
            ${state.journal.tests
              .map((t) => `<option value="${esc(t)}" ${f.test === t ? 'selected' : ''}>${esc(t)}</option>`)
              .join('')}
          </select>
          <input id="jfSearch" class="input" type="search" placeholder="Поиск по ФИО..." value="${esc(f.q)}" style="max-width:220px">
        </div>
        <a href="/api/journal/export?${exportParams.toString()}" class="btn btn-sm">Экспорт CSV</a>
      </div>

      <div class="card table-wrap">
        ${
          state.journal.records.length === 0
            ? `<div class="empty-state">Записей пока нет</div>`
            : `<table>
                <thead>
                  <tr>
                    <th>Дата</th>
                    <th>Группа</th>
                    <th>ФИО</th>
                    <th>Тест</th>
                    <th>Статус</th>
                    <th>Баллы</th>
                    <th>Оценка</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  ${state.journal.records
                    .map((r) => {
                      const stBadge =
                        r.status === 'violated'
                          ? `<span class="badge badge-red" title="${esc(r.violation_reason)}">Нарушение</span>`
                          : r.status === 'submitted'
                          ? '<span class="badge badge-green">Сдал</span>'
                          : '<span class="badge badge-blue">Решает</span>';
                      return `
                        <tr>
                          <td style="white-space:nowrap;color:var(--text-muted);font-size:13px">${esc(r.date.slice(0, 16))}</td>
                          <td><span class="badge badge-gray">${esc(r.group_name)}</span></td>
                          <td><strong>${esc(r.student_name)}</strong></td>
                          <td>${esc(r.test_title)}</td>
                          <td>${stBadge}</td>
                          <td style="white-space:nowrap">${r.score}/${r.max_score} <span style="color:var(--text-muted)">(${r.percent}%)</span></td>
                          <td>
                            <input class="grade-inline" data-grade-id="${r.id}" value="${esc(r.grade)}" title="Изменить оценку">
                          </td>
                          <td style="white-space:nowrap;text-align:right">
                            <button class="btn btn-sm" data-view-att="${r.id}">Ответы</button>
                            <button class="btn btn-ghost btn-sm" style="color:var(--danger)" data-del-att="${r.id}">×</button>
                          </td>
                        </tr>`;
                    })
                    .join('')}
                </tbody>
              </table>`
        }
      </div>
    `;

    document.getElementById('jfGroup').addEventListener('change', async (e) => {
      f.group = e.target.value;
      await loadJournal();
      renderTabContent();
    });
    document.getElementById('jfTest').addEventListener('change', async (e) => {
      f.test = e.target.value;
      await loadJournal();
      renderTabContent();
    });
    let st;
    document.getElementById('jfSearch').addEventListener('input', (e) => {
      f.q = e.target.value;
      clearTimeout(st);
      st = setTimeout(async () => {
        await loadJournal();
        renderTabContent();
        const inp = document.getElementById('jfSearch');
        if (inp) {
          inp.focus();
          inp.setSelectionRange(inp.value.length, inp.value.length);
        }
      }, 220);
    });

    root.querySelectorAll('[data-grade-id]').forEach((inp) => {
      const saveGrade = async () => {
        await api(`/api/attempts/${inp.dataset.gradeId}/grade`, {
          method: 'POST',
          body: JSON.stringify({ grade: inp.value.trim() }),
        });
        toast('Оценка обновлена', 'success');
      };
      inp.addEventListener('change', saveGrade);
    });

    root.querySelectorAll('[data-view-att]').forEach((b) => {
      b.addEventListener('click', () => openAttemptDetails(Number(b.dataset.viewAtt)));
    });

    root.querySelectorAll('[data-del-att]').forEach((b) => {
      b.addEventListener('click', async () => {
        if (!confirm('Удалить запись из журнала?')) return;
        await api(`/api/attempts/${b.dataset.delAtt}`, { method: 'DELETE' });
        await loadJournal();
        renderTabContent();
      });
    });
  }

  // Детали попытки ученика (ответы по каждому вопросу + смена оценки)
  async function openAttemptDetails(attemptId) {
    try {
      const data = await api(`/api/attempts/${attemptId}/details`);
      const a = data.attempt;
      const s = data.session;
      modalRoot.innerHTML = `
        <div class="modal-backdrop" id="detBackdrop">
          <div class="modal" style="max-width:700px">
            <div class="modal-head">
              <div>
                <h3>${esc(a.student_name)}</h3>
                <div style="font-size:12.5px;color:var(--text-muted);margin-top:2px">
                  ${esc(s.group_name)} · ${esc(s.test_title)} · Баллы: ${a.score}/${a.max_score} (${a.percent}%)
                </div>
              </div>
              <button class="btn btn-ghost btn-sm" id="closeDetModal">×</button>
            </div>
            <div class="modal-body">
              ${
                a.violation_count > 0
                  ? `<div class="alert-item" style="margin-bottom:14px">
                      <div class="alert-item-text">
                        <strong>Нарушения (${a.violation_count}):</strong> ${esc(a.violation_reason)}
                        ${a.unlock_count > 0 ? ` · Разблокировок: ${a.unlock_count}` : ''}
                      </div>
                    </div>`
                  : ''
              }
              <div class="row" style="margin-bottom:16px;padding:10px 14px;background:var(--surface-subtle);border-radius:8px">
                <span style="font-size:13.5px;font-weight:500">Оценка:</span>
                <input id="detGradeInput" class="input" style="width:90px;padding:6px 10px;font-weight:700" value="${esc(a.grade)}">
                <button id="detSaveGrade" class="btn btn-primary btn-sm">Сохранить</button>
              </div>
              ${data.breakdown
                .map(
                  (item, idx) => `
                  <div class="breakdown-item ${item.is_correct ? 'ok' : 'bad'}">
                    <div style="font-weight:600;margin-bottom:6px">${idx + 1}. ${esc(item.text)}</div>
                    <div style="font-size:13.5px">
                      <span style="color:var(--text-muted)">Ответ:</span>
                      <strong style="color:${item.is_correct ? 'var(--success)' : 'var(--danger)'}">${esc(item.student_answer)}</strong>
                    </div>
                    ${
                      !item.is_correct
                        ? `<div style="font-size:13px;margin-top:3px;color:var(--text-muted)">
                            Правильный: <strong>${esc(item.correct_answer)}</strong>
                          </div>`
                        : ''
                    }
                  </div>`
                )
                .join('')}
            </div>
            <div class="modal-foot">
              <button class="btn" id="okDetModal">Закрыть</button>
            </div>
          </div>
        </div>`;

      const close = () => (modalRoot.innerHTML = '');
      document.getElementById('closeDetModal').addEventListener('click', close);
      document.getElementById('okDetModal').addEventListener('click', close);
      document.getElementById('detBackdrop').addEventListener('click', (e) => {
        if (e.target.id === 'detBackdrop') close();
      });
      document.getElementById('detSaveGrade').addEventListener('click', async () => {
        const g = document.getElementById('detGradeInput').value.trim();
        await api(`/api/attempts/${attemptId}/grade`, {
          method: 'POST',
          body: JSON.stringify({ grade: g }),
        });
        toast('Оценка сохранена', 'success');
        if (state.tab === 'journal') {
          await loadJournal();
          renderTabContent();
        }
      });
    } catch (err) {
      toast(err.message, 'error');
    }
  }

  // =========================================================================
  // ВКЛАДКА 5: НАСТРОЙКИ
  // =========================================================================
  function renderSettingsTab(root) {
    const st = state.settings;
    root.innerHTML = `
      <div class="grid-2" style="align-items:start">
        <div class="card card-pad">
          <h3 style="margin:0 0 14px;font-size:16px">Шкала оценивания</h3>
          <div class="field">
            <label class="label">Шкала по умолчанию</label>
            <select id="setScale" class="select">
              <option value="10" ${st.grading_scale === '10' ? 'selected' : ''}>10-балльная</option>
              <option value="5" ${st.grading_scale === '5' ? 'selected' : ''}>5-балльная</option>
              <option value="points" ${st.grading_scale === 'points' ? 'selected' : ''}>Только баллы</option>
            </select>
          </div>
          <div class="field">
            <label class="check-row">
              <input type="checkbox" id="setSound" ${st.sound_enabled ? 'checked' : ''}>
              <span>Звуковой сигнал при нарушении</span>
            </label>
          </div>

          <div class="field">
            <label class="label">Пороги (% для 10-балльной шкалы)</label>
            <div style="display:grid;grid-template-columns:repeat(5, 1fr);gap:6px">
              ${st.scale_10
                .map(
                  (item, i) => `
                  <div style="text-align:center">
                    <div style="font-size:12px;font-weight:700;margin-bottom:3px">${esc(item.grade)}</div>
                    <input class="input" data-s10="${i}" type="number" min="0" max="100" value="${item.min}" style="padding:5px;text-align:center">
                  </div>`
                )
                .join('')}
            </div>
          </div>

          <div class="field">
            <label class="label">Пороги (% для 5-балльной шкалы)</label>
            <div style="display:grid;grid-template-columns:repeat(4, 1fr);gap:6px">
              ${st.scale_5
                .map(
                  (item, i) => `
                  <div style="text-align:center">
                    <div style="font-size:12px;font-weight:700;margin-bottom:3px">${esc(item.grade)}</div>
                    <input class="input" data-s5="${i}" type="number" min="0" max="100" value="${item.min}" style="padding:5px;text-align:center">
                  </div>`
                )
                .join('')}
            </div>
          </div>

          <button id="saveSettingsBtn" class="btn btn-primary">Сохранить настройки</button>
        </div>

        <div style="display:flex;flex-direction:column;gap:14px">
          <div class="card card-pad">
            <h3 style="margin:0 0 14px;font-size:16px">Смена пароля</h3>
            <form id="pwForm">
              <div class="field">
                <label class="label">Текущий пароль</label>
                <input id="oldPw" class="input" type="password" required>
              </div>
              <div class="field">
                <label class="label">Новый пароль</label>
                <input id="newPw" class="input" type="password" minlength="3" required>
              </div>
              <button type="submit" class="btn btn-primary">Изменить пароль</button>
            </form>
          </div>

          <div class="card card-pad">
            <h3 style="margin:0 0 10px;font-size:16px">База данных</h3>
            <div style="font-size:13px;color:var(--text-muted);margin-bottom:14px">
              Все тесты, группы и оценки хранятся в локальном файле classtest.db рядом с программой.
            </div>
            <a href="/api/backup" class="btn">Скачать копию базы (.db)</a>
          </div>
        </div>
      </div>
    `;

    document.getElementById('saveSettingsBtn').addEventListener('click', async () => {
      st.grading_scale = document.getElementById('setScale').value;
      st.sound_enabled = document.getElementById('setSound').checked;
      root.querySelectorAll('[data-s10]').forEach((inp) => {
        st.scale_10[Number(inp.dataset.s10)].min = Number(inp.value) || 0;
      });
      root.querySelectorAll('[data-s5]').forEach((inp) => {
        st.scale_5[Number(inp.dataset.s5)].min = Number(inp.value) || 0;
      });
      await api('/api/settings', { method: 'POST', body: JSON.stringify(st) });
      toast('Настройки сохранены', 'success');
    });

    document.getElementById('pwForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      try {
        await api('/api/settings/password', {
          method: 'POST',
          body: JSON.stringify({
            old_password: document.getElementById('oldPw').value,
            new_password: document.getElementById('newPw').value,
          }),
        });
        document.getElementById('oldPw').value = '';
        document.getElementById('newPw').value = '';
        toast('Пароль изменён', 'success');
      } catch (err) {
        toast(err.message, 'error');
      }
    });
  }

  // -------------------------------------------------------------------------
  // Инициализация
  // -------------------------------------------------------------------------
  async function boot() {
    try {
      const me = await api('/api/auth/me');
      state.authed = Boolean(me.authenticated);
      if (state.authed) {
        await loadAllData();
        connectSSE();
      }
    } catch {
      state.authed = false;
    }
    render();
  }

  boot();
})();
