(() => {
  const app = document.getElementById('app');
  const blackout = document.getElementById('blackout');
  const watermark = document.getElementById('watermark');
  const toasts = document.getElementById('toasts');

  const STORAGE_KEY = 'ct_student_token';

  const state = {
    view: 'loading', // loading | waiting | join | exam | locked | submitted
    session: null,
    attempt: null,
    recentResult: null,
    currentIndex: 0,
    answers: {},
    remainingSec: null,
    timerId: null,
    sse: null,
    armed: false,
    armTimer: null,
    submitting: false,
    watermarkTimer: null,
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
    if (!res.ok) throw new Error(data.error || 'Ошибка сервера');
    return data;
  }

  function getToken() {
    try { return localStorage.getItem(STORAGE_KEY) || ''; } catch { return ''; }
  }
  function setToken(t) {
    try {
      if (t) localStorage.setItem(STORAGE_KEY, t);
      else localStorage.removeItem(STORAGE_KEY);
    } catch {}
  }

  function formatTime(sec) {
    if (sec === null || sec === undefined) return '';
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
  }

  // Водяной знак (ФИО + группа + время)
  function updateWatermark() {
    if (state.view !== 'exam' || !state.attempt || !state.session) {
      watermark.classList.add('hidden');
      watermark.style.backgroundImage = '';
      return;
    }
    const now = new Date();
    const hm = String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0');
    const text = `${state.attempt.student_name} • ${state.session.group_name} • ${hm}`;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="170">
      <text x="160" y="95" text-anchor="middle" font-family="sans-serif" font-size="14" font-weight="600" fill="#0f172a" transform="rotate(-24 160 95)">${esc(text)}</text>
    </svg>`;
    watermark.style.backgroundImage = `url("data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}")`;
    watermark.classList.remove('hidden');
  }

  // -------------------------------------------------------------------------
  // Античит
  // -------------------------------------------------------------------------
  function armAntiCheat() {
    disarmAntiCheat();
    document.body.classList.add('exam-protected');
    updateWatermark();
    state.watermarkTimer = setInterval(updateWatermark, 30000);
    // Задержка 900мс для плавного входа в полноэкранный режим без ложного срабатывания
    state.armTimer = setTimeout(() => {
      state.armed = true;
    }, 900);
  }

  function disarmAntiCheat() {
    state.armed = false;
    clearTimeout(state.armTimer);
    clearInterval(state.watermarkTimer);
    document.body.classList.remove('exam-protected');
    blackout.classList.remove('active');
    watermark.classList.add('hidden');
  }

  let violationInFlight = false;
  async function triggerViolation(reason) {
    if (!state.armed || state.view !== 'exam' || state.submitting || violationInFlight) return;
    violationInFlight = true;
    state.armed = false;
    clearInterval(state.timerId);
    const token = state.attempt?.token || getToken();
    try {
      const res = await api('/api/student/violation', {
        method: 'POST',
        body: JSON.stringify({ token, reason, answers: state.answers }),
      });
      state.attempt.status = 'violated';
      state.attempt.violation_reason = res.reason || reason;
      state.attempt.grade = res.grade || '';
      state.view = 'locked';
      disarmAntiCheat();
      render();
    } catch {
      state.attempt.status = 'violated';
      state.attempt.violation_reason = reason;
      state.view = 'locked';
      disarmAntiCheat();
      render();
    } finally {
      violationInFlight = false;
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.hidden && state.armed && state.view === 'exam') {
      blackout.classList.add('active');
      triggerViolation('Сворачивание браузера или смена вкладки');
    }
  });

  window.addEventListener('blur', () => {
    if (state.armed && state.view === 'exam') {
      blackout.classList.add('active');
      setTimeout(() => {
        if (!document.hasFocus() && state.armed && state.view === 'exam') {
          triggerViolation('Потеря фокуса окна');
        } else if (document.hasFocus() && state.view === 'exam') {
          blackout.classList.remove('active');
        }
      }, 150);
    }
  });

  window.addEventListener('focus', () => {
    if (state.view === 'exam') blackout.classList.remove('active');
  });

  document.addEventListener('fullscreenchange', () => {
    if (
      state.armed &&
      state.view === 'exam' &&
      state.session?.require_fullscreen &&
      !document.fullscreenElement
    ) {
      triggerViolation('Выход из полноэкранного режима');
    }
  });

  window.addEventListener('pagehide', () => {
    if (state.armed && state.view === 'exam' && !state.submitting) {
      const token = state.attempt?.token || getToken();
      if (token && navigator.sendBeacon) {
        const blob = new Blob(
          [JSON.stringify({ token, reason: 'Закрытие или перезагрузка страницы', answers: state.answers })],
          { type: 'application/json' }
        );
        navigator.sendBeacon('/api/student/violation', blob);
      }
    }
  });

  // Запрет контекстного меню, копирования и PrintScreen
  document.addEventListener('contextmenu', (e) => {
    if (state.view === 'exam') e.preventDefault();
  });
  ['copy', 'cut', 'paste', 'dragstart'].forEach((ev) => {
    document.addEventListener(ev, (e) => {
      if (state.view === 'exam' && !(ev === 'paste' && e.target.tagName === 'INPUT')) {
        e.preventDefault();
      }
    });
  });

  function handleScreenshotKey(e) {
    if (state.view !== 'exam' || !state.armed) return;
    const blockPs = state.session?.block_printscreen !== false;
    if (
      blockPs &&
      (e.key === 'PrintScreen' ||
        e.code === 'PrintScreen' ||
        ((e.metaKey || e.ctrlKey) && e.shiftKey && ['s', 'S', '3', '4', '5'].includes(e.key)))
    ) {
      e.preventDefault();
      blackout.classList.add('active');
      triggerViolation('Попытка сделать скриншот');
      return;
    }
    if (
      e.key === 'F12' ||
      ((e.ctrlKey || e.metaKey) && e.shiftKey && ['I', 'J', 'C', 'i', 'j', 'c'].includes(e.key)) ||
      ((e.ctrlKey || e.metaKey) && ['u', 'U', 'c', 'C', 'p', 'P'].includes(e.key))
    ) {
      e.preventDefault();
    }
  }
  window.addEventListener('keydown', handleScreenshotKey, true);
  window.addEventListener('keyup', handleScreenshotKey, true);

  // -------------------------------------------------------------------------
  // SSE подключение
  // -------------------------------------------------------------------------
  function connectSSE() {
    if (state.sse) {
      state.sse.close();
      state.sse = null;
    }
    const token = getToken();
    const url = token ? `/api/events/student?token=${encodeURIComponent(token)}` : '/api/events/student';
    const es = new EventSource(url);
    state.sse = es;

    es.addEventListener('session_changed', () => {
      if (state.view === 'waiting' || state.view === 'join') {
        loadStatus();
      }
    });

    es.addEventListener('unblock', () => {
      if (state.view === 'locked') {
        toast('Доступ восстановлен', 'success');
        loadStatus();
      }
    });

    es.addEventListener('session_ended', () => {
      disarmAntiCheat();
      clearInterval(state.timerId);
      if (document.fullscreenElement) {
        document.exitFullscreen().catch(() => {});
      }
      loadStatus();
    });
  }

  // -------------------------------------------------------------------------
  // Загрузка статуса
  // -------------------------------------------------------------------------
  async function loadStatus() {
    try {
      const token = getToken();
      const data = await api('/api/student/status' + (token ? `?token=${encodeURIComponent(token)}` : ''));
      if (!data.active) {
        disarmAntiCheat();
        clearInterval(state.timerId);
        state.session = null;
        if (data.recent_result) {
          state.recentResult = data.recent_result;
          state.view = data.recent_result.status === 'violated' ? 'locked' : 'submitted';
        } else {
          state.recentResult = null;
          state.attempt = null;
          state.view = 'waiting';
        }
        render();
        return;
      }

      state.session = data.session;
      state.recentResult = null;

      if (!data.attempt) {
        disarmAntiCheat();
        clearInterval(state.timerId);
        state.attempt = null;
        state.view = 'join';
        render();
        return;
      }

      state.attempt = data.attempt;
      state.answers = data.attempt.answers || {};
      setToken(data.attempt.token);

      if (data.attempt.status === 'violated') {
        disarmAntiCheat();
        clearInterval(state.timerId);
        state.view = 'locked';
        render();
      } else if (data.attempt.status === 'submitted') {
        disarmAntiCheat();
        clearInterval(state.timerId);
        state.view = 'submitted';
        render();
      } else {
        state.view = 'exam';
        if (state.currentIndex >= (state.attempt.questions?.length || 1)) {
          state.currentIndex = 0;
        }
        startTimer(data.attempt.remaining_seconds);
        render();
        armAntiCheat();
      }
    } catch {
      setTimeout(loadStatus, 2500);
    }
  }

  function startTimer(seconds) {
    clearInterval(state.timerId);
    state.remainingSec = seconds;
    if (seconds === null || seconds === undefined) return;
    state.timerId = setInterval(() => {
      if (state.remainingSec <= 0) {
        clearInterval(state.timerId);
        submitExam(true);
        return;
      }
      state.remainingSec -= 1;
      const el = document.getElementById('timerDisplay');
      if (el) {
        el.textContent = formatTime(state.remainingSec);
        el.classList.toggle('urgent', state.remainingSec <= 120);
      }
    }, 1000);
  }

  let progressTimer = null;
  function saveProgress() {
    clearTimeout(progressTimer);
    progressTimer = setTimeout(async () => {
      if (state.view !== 'exam' || !state.attempt) return;
      try {
        await api('/api/student/progress', {
          method: 'POST',
          body: JSON.stringify({ token: state.attempt.token, answers: state.answers }),
        });
      } catch {}
    }, 180);
  }

  async function submitExam(auto = false) {
    if (state.submitting || state.view !== 'exam') return;
    if (!auto) {
      const total = state.attempt.questions.length;
      const answered = countAnswered();
      const msg = answered < total
        ? `Отвечено на ${answered} из ${total}. Завершить работу?`
        : 'Завершить и сдать работу?';
      if (!confirm(msg)) return;
    }
    state.submitting = true;
    disarmAntiCheat();
    clearInterval(state.timerId);
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => {});
    }
    try {
      const res = await api('/api/student/submit', {
        method: 'POST',
        body: JSON.stringify({ token: state.attempt.token, answers: state.answers }),
      });
      state.attempt.status = res.status;
      state.attempt.score = res.score;
      state.attempt.max_score = res.max_score;
      state.attempt.percent = res.percent;
      state.attempt.grade = res.grade;
      state.view = 'submitted';
      render();
    } catch (e) {
      toast(e.message, 'error');
      state.submitting = false;
      armAntiCheat();
    } finally {
      state.submitting = false;
    }
  }

  function countAnswered() {
    return Object.values(state.answers).filter((v) =>
      Array.isArray(v) ? v.length > 0 : String(v ?? '').trim() !== ''
    ).length;
  }

  // -------------------------------------------------------------------------
  // Рендеринг экранов
  // -------------------------------------------------------------------------
  function render() {
    if (state.view === 'loading') {
      app.innerHTML = `<div class="student-center"><div class="card student-card-box" style="text-align:center;color:var(--text-muted)">Подключение...</div></div>`;
      return;
    }

    if (state.view === 'waiting') {
      app.innerHTML = `
        <div class="student-center">
          <div class="card student-card-box" style="text-align:center">
            <div class="brand" style="justify-content:center;margin-bottom:18px">
              <div class="brand-mark">К</div>
              <span>КлассТест</span>
            </div>
            <div style="display:inline-flex;align-items:center;gap:8px;color:var(--text-muted);font-size:15px">
              <span class="live-dot" style="background:var(--primary)"></span>
              Ожидание начала контрольной
            </div>
          </div>
        </div>`;
      return;
    }

    if (state.view === 'join') {
      const s = state.session;
      const hasRoster = Array.isArray(s.roster) && s.roster.length > 0;
      const takenSet = new Set((s.taken_names || []).map((n) => n.toLowerCase()));
      const timeLabel = s.time_limit > 0 ? `${s.time_limit} мин` : 'Без ограничения времени';

      app.innerHTML = `
        <div class="student-center">
          <div class="card student-card-box">
            <div class="row-between" style="margin-bottom:14px">
              <span class="badge badge-blue">${esc(s.group_name)}</span>
              <span style="font-size:13px;color:var(--text-muted)">${s.questions_count} вопр. · ${timeLabel}</span>
            </div>
            <h2 style="margin:0 0 18px;font-size:20px">${esc(s.test_title)}</h2>
            <form id="joinForm">
              <div class="field">
                <label class="label">${hasRoster ? 'Выберите себя из списка' : 'Фамилия и имя'}</label>
                ${
                  hasRoster
                    ? `<select id="studentNameInput" class="select" required>
                        <option value="">— Выбрать —</option>
                        ${s.roster
                          .map((name) => {
                            const used = takenSet.has(name.toLowerCase());
                            return `<option value="${esc(name)}">${esc(name)}${used ? ' (подключен)' : ''}</option>`;
                          })
                          .join('')}
                      </select>`
                    : `<input id="studentNameInput" class="input" type="text" placeholder="Иванов Иван" autocomplete="name" required autofocus>`
                }
              </div>
              <div style="font-size:12.5px;color:var(--text-muted);margin-bottom:16px">
                Не сворачивайте браузер и не переключайте вкладки во время выполнения.
              </div>
              <button type="submit" class="btn btn-primary btn-lg" style="width:100%">Начать</button>
            </form>
          </div>
        </div>`;

      document.getElementById('joinForm').addEventListener('submit', async (e) => {
        e.preventDefault();
        const name = document.getElementById('studentNameInput').value.trim();
        if (!name) return;
        const btn = e.target.querySelector('button[type="submit"]');
        btn.disabled = true;
        try {
          if (s.require_fullscreen && document.documentElement.requestFullscreen) {
            await document.documentElement.requestFullscreen().catch(() => {});
          }
          const res = await api('/api/student/join', {
            method: 'POST',
            body: JSON.stringify({ student_name: name }),
          });
          setToken(res.token);
          connectSSE();
          await loadStatus();
        } catch (err) {
          toast(err.message, 'error');
          btn.disabled = false;
        }
      });
      return;
    }

    if (state.view === 'locked') {
      const info = state.recentResult || state.attempt || {};
      const gradeStr = info.grade && info.grade !== '—' ? `Выставлена оценка: ${esc(info.grade)}` : 'Уведомление отправлено учителю';
      app.innerHTML = `
        <div class="student-center">
          <div class="card student-card-box lock-screen">
            <div class="badge badge-red" style="margin-bottom:12px">Тест завершён</div>
            <h2 style="margin:0 0 8px;font-size:21px">Зафиксирован выход</h2>
            <div style="color:var(--text-muted);font-size:14px;margin-bottom:14px">${esc(info.violation_reason || 'Прерывание работы')}</div>
            ${info.grade && info.grade !== '—' ? `<div class="big-grade danger">${esc(info.grade)}</div>` : ''}
            <div style="font-size:13.5px;color:var(--text-muted);margin-top:8px">${gradeStr}</div>
          </div>
        </div>`;
      return;
    }

    if (state.view === 'submitted') {
      const info = state.recentResult || state.attempt || {};
      app.innerHTML = `
        <div class="student-center">
          <div class="card student-card-box result-screen">
            <div class="badge badge-green" style="margin-bottom:10px">Работа сдана</div>
            <div style="font-weight:600;font-size:16px">${esc(info.student_name || '')}</div>
            <div class="big-grade">${esc(info.grade || '—')}</div>
            <div style="color:var(--text-muted);font-size:14px;margin-bottom:18px">
              Баллы: ${esc(info.score)} из ${esc(info.max_score)} (${esc(info.percent)}%)
            </div>
            ${
              !state.session
                ? `<button id="resetBtn" class="btn btn-sm">На главный экран</button>`
                : ''
            }
          </div>
        </div>`;
      const rb = document.getElementById('resetBtn');
      if (rb) {
        rb.addEventListener('click', () => {
          setToken('');
          state.recentResult = null;
          state.attempt = null;
          connectSSE();
          loadStatus();
        });
      }
      return;
    }

    if (state.view === 'exam') {
      const qs = state.attempt.questions || [];
      const q = qs[state.currentIndex];
      if (!q) return;
      const ans = state.answers[q.id];
      const answeredCount = countAnswered();

      app.innerHTML = `
        <header class="exam-topbar">
          <div class="row" style="gap:10px">
            <span class="badge badge-blue">${esc(state.session.group_name)}</span>
            <strong>${esc(state.attempt.student_name)}</strong>
            <span style="color:var(--text-muted);font-size:13px">${answeredCount} / ${qs.length}</span>
          </div>
          <div class="row" style="gap:10px">
            ${
              state.remainingSec !== null
                ? `<div id="timerDisplay" class="exam-timer ${state.remainingSec <= 120 ? 'urgent' : ''}">${formatTime(state.remainingSec)}</div>`
                : ''
            }
            <button id="finishBtn" class="btn btn-primary btn-sm">Завершить</button>
          </div>
        </header>

        <main class="exam-main">
          <div class="q-pills">
            ${qs
              .map((item, idx) => {
                const v = state.answers[item.id];
                const isAns = Array.isArray(v) ? v.length > 0 : String(v ?? '').trim() !== '';
                const cls = idx === state.currentIndex ? 'current' : isAns ? 'answered' : '';
                return `<button class="q-pill ${cls}" data-idx="${idx}">${idx + 1}</button>`;
              })
              .join('')}
          </div>

          <div class="card exam-q-card">
            <div class="row-between" style="margin-bottom:12px">
              <span style="font-size:13px;font-weight:600;color:var(--text-muted)">Вопрос ${state.currentIndex + 1} из ${qs.length}</span>
              <span style="font-size:12.5px;color:var(--text-muted)">${
                q.type === 'multiple' ? 'Несколько ответов' : q.type === 'text' ? 'Текстовый ответ' : 'Один ответ'
              } · ${q.points} б.</span>
            </div>
            <div class="exam-q-text">${esc(q.text)}</div>
            <div id="answerArea">
              ${renderQuestionInput(q, ans)}
            </div>
          </div>

          <div class="row-between">
            <button id="prevBtn" class="btn" ${state.currentIndex === 0 ? 'disabled' : ''}>← Назад</button>
            ${
              state.currentIndex < qs.length - 1
                ? `<button id="nextBtn" class="btn btn-primary">Далее →</button>`
                : `<button id="submitBottomBtn" class="btn btn-success">Сдать работу</button>`
            }
          </div>
        </main>`;

      // Навигация по номерам
      app.querySelectorAll('.q-pill').forEach((btn) => {
        btn.addEventListener('click', () => {
          state.currentIndex = Number(btn.dataset.idx);
          render();
        });
      });

      document.getElementById('finishBtn').addEventListener('click', () => submitExam(false));
      const prevBtn = document.getElementById('prevBtn');
      if (prevBtn) prevBtn.addEventListener('click', () => { state.currentIndex--; render(); });
      const nextBtn = document.getElementById('nextBtn');
      if (nextBtn) nextBtn.addEventListener('click', () => { state.currentIndex++; render(); });
      const submitBottom = document.getElementById('submitBottomBtn');
      if (submitBottom) submitBottom.addEventListener('click', () => submitExam(false));

      // Обработка ответов
      if (q.type === 'single') {
        app.querySelectorAll('.exam-opt').forEach((row) => {
          row.addEventListener('click', () => {
            state.answers[q.id] = Number(row.dataset.val);
            saveProgress();
            render();
          });
        });
      } else if (q.type === 'multiple') {
        app.querySelectorAll('.exam-opt').forEach((row) => {
          row.addEventListener('click', () => {
            const val = Number(row.dataset.val);
            const cur = Array.isArray(state.answers[q.id]) ? [...state.answers[q.id]] : [];
            const idx = cur.indexOf(val);
            if (idx >= 0) cur.splice(idx, 1);
            else cur.push(val);
            state.answers[q.id] = cur;
            saveProgress();
            render();
          });
        });
      } else if (q.type === 'text') {
        const inp = document.getElementById('textAnswerInput');
        if (inp) {
          inp.addEventListener('input', () => {
            state.answers[q.id] = inp.value;
            saveProgress();
          });
        }
      }
    }
  }

  function renderQuestionInput(q, ans) {
    if (q.type === 'single') {
      return (q.options || [])
        .map((opt) => {
          const checked = ans !== undefined && ans !== '' && Number(ans) === opt.index;
          return `<div class="exam-opt ${checked ? 'selected' : ''}" data-val="${opt.index}">
            <input type="radio" name="q_${esc(q.id)}" ${checked ? 'checked' : ''} tabindex="-1">
            <span>${esc(opt.text)}</span>
          </div>`;
        })
        .join('');
    }
    if (q.type === 'multiple') {
      const arr = Array.isArray(ans) ? ans.map(Number) : [];
      return (q.options || [])
        .map((opt) => {
          const checked = arr.includes(opt.index);
          return `<div class="exam-opt ${checked ? 'selected' : ''}" data-val="${opt.index}">
            <input type="checkbox" ${checked ? 'checked' : ''} tabindex="-1">
            <span>${esc(opt.text)}</span>
          </div>`;
        })
        .join('');
    }
    return `<input id="textAnswerInput" class="input" type="text" placeholder="Введите ответ" value="${esc(ans || '')}" autocomplete="off">`;
  }

  // Мост для нативных приложений Android и iOS
  window.__isExamActive = () => state.view === 'exam' && state.armed;
  window.__nativeViolation = (reason) => {
    if (state.view === 'exam' && state.armed && !state.submitting) {
      blackout.classList.add('active');
      triggerViolation(reason || 'Нарушение в приложении');
    }
  };

  connectSSE();
  loadStatus();
})();
