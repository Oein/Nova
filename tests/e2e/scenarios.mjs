// E2E scenarios, driven against the mock-backend preview build.
// Each scenario is a plain JS body that runs inside the page (`preview_eval`
// semantics). The harness in run.mjs boots vite and evaluates each scenario
// via the Claude Preview MCP; within a single conversation Claude can also
// paste the body below into `preview_eval` directly.
//
// Scenario contract: return `{ pass: boolean, detail: unknown }`.
//
// After the workspace refactor, notes are identified by opaque note IDs and
// sidebar entries expose `data-note-id`. Fixture workspace root is
// `/mock/workspace` and seeded note IDs are `note-1`…`note-9`.

export const scenarios = [
  {
    id: "01_sidebar_listing",
    title: "Sidebar lists notes, grouped by local day",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 1500));
      const groups = [...document.querySelectorAll('button[data-group-key]')];
      const entries = [...document.querySelectorAll('button[data-note-id]')];
      return {
        pass: groups.length >= 2 && entries.length >= 8,
        detail: { groupCount: groups.length, entryCount: entries.length },
      };
    })()`,
  },
  {
    id: "02_collapse_persist",
    title: "Collapsed group state persists in localStorage",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 800));
      const yesterday = [...document.querySelectorAll('button[data-group-key]')]
        .find(b => b.textContent.includes('Yesterday'));
      if (!yesterday) return { pass: false, detail: 'no Yesterday group' };
      const key = yesterday.getAttribute('data-group-key');
      yesterday.click();
      await new Promise(r => setTimeout(r, 100));
      const stored = localStorage.getItem('collapsedGroups:/mock/workspace');
      yesterday.click(); // restore
      return {
        pass: !!stored && stored.includes(key),
        detail: { stored, key },
      };
    })()`,
  },
  {
    id: "03_edit_save_updates_title",
    title: "Typing + Cmd+S writes through and updates the first-line title",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      const target = document.querySelector('button[data-note-id="note-3"]');
      const beforeTitle = target.querySelector('.name')?.textContent;
      target.click();
      await new Promise(r => setTimeout(r, 400));
      const inp = document.querySelector('.hidden-input');
      inp.focus();
      // Jump to start, then insert a new first line.
      inp.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', metaKey: true, bubbles: true, cancelable: true }));
      inp.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'E2E new title\\n', cancelable: true, bubbles: true }));
      await new Promise(r => setTimeout(r, 120));
      inp.dispatchEvent(new KeyboardEvent('keydown', { key: 's', metaKey: true, bubbles: true, cancelable: true }));
      await new Promise(r => setTimeout(r, 350));
      const storedContent = window.__mock.getNote('note-3').content;
      const afterTitle = document.querySelector('button[data-note-id="note-3"] .name')?.textContent;
      return {
        pass: storedContent.startsWith('E2E new title') && afterTitle === 'E2E new title' && beforeTitle !== afterTitle,
        detail: { beforeTitle, afterTitle, storedStart: storedContent.slice(0, 40) },
      };
    })()`,
  },
  {
    id: "04_ime_hangul",
    title: "IME compositionstart/update/end commits final syllables",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      document.querySelector('button[data-note-id="note-1"]').click();
      await new Promise(r => setTimeout(r, 400));
      const inp = document.querySelector('.hidden-input');
      inp.focus();
      inp.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }));
      inp.dispatchEvent(new CompositionEvent('compositionupdate', { data: 'ㅎ', bubbles: true }));
      inp.dispatchEvent(new CompositionEvent('compositionupdate', { data: '하', bubbles: true }));
      inp.dispatchEvent(new CompositionEvent('compositionend', { data: '한글', bubbles: true }));
      await new Promise(r => setTimeout(r, 200));
      const firstRow = document.querySelector('.row')?.textContent || '';
      return { pass: firstRow.includes('한글'), detail: { firstRow } };
    })()`,
  },
  {
    id: "05_undo_redo",
    title: "Cmd+Z / Cmd+Shift+Z round-trip after a type",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      document.querySelector('button[data-note-id="note-2"]').click();
      await new Promise(r => setTimeout(r, 400));
      const inp = document.querySelector('.hidden-input');
      inp.focus();
      const before = document.querySelector('.row')?.textContent;
      inp.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'X', cancelable: true, bubbles: true }));
      await new Promise(r => setTimeout(r, 120));
      const afterType = document.querySelector('.row')?.textContent;
      inp.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true, cancelable: true }));
      await new Promise(r => setTimeout(r, 150));
      const afterUndo = document.querySelector('.row')?.textContent;
      inp.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: true, bubbles: true, cancelable: true }));
      await new Promise(r => setTimeout(r, 150));
      const afterRedo = document.querySelector('.row')?.textContent;
      return {
        pass: afterType !== before && afterUndo === before && afterRedo === afterType,
        detail: { before, afterType, afterUndo, afterRedo },
      };
    })()`,
  },
  {
    id: "06_new_note",
    title: "Clicking + creates a fresh note and opens its tab",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      const idsBefore = window.__mock.listIds();
      document.querySelector('button[aria-label="New note"]').click();
      await new Promise(r => setTimeout(r, 400));
      const idsAfter = window.__mock.listIds();
      const created = idsAfter.find(id => !idsBefore.includes(id));
      const activeTab = document.querySelector('.tab.active');
      return {
        pass: !!created && !!activeTab && activeTab.textContent.includes('Untitled'),
        detail: { created, activeText: activeTab?.textContent },
      };
    })()`,
  },
  {
    id: "07_tab_switch_updates_content",
    title: "Switching tabs shows the buffer of the active note",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      document.querySelector('button[data-note-id="note-1"]').click();
      await new Promise(r => setTimeout(r, 300));
      const textA = [...document.querySelectorAll('.row')].map(r => r.textContent).join('\\n');
      document.querySelector('button[data-note-id="note-6"]').click();
      await new Promise(r => setTimeout(r, 300));
      const textB = [...document.querySelectorAll('.row')].map(r => r.textContent).join('\\n');
      return {
        pass: textA !== textB && textA.includes('Project notes') && textB.includes('Changelog'),
        detail: { textA: textA.slice(0, 40), textB: textB.slice(0, 40) },
      };
    })()`,
  },
  {
    id: "08_session_restore_unsaved_and_undo",
    title: "Session restore preserves unsaved content, cursor, and undo history",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      document.querySelector('button[data-note-id="note-1"]').click();
      await new Promise(r => setTimeout(r, 300));
      const inp = document.querySelector('.hidden-input');
      inp.focus();
      inp.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'UNSAVED', cancelable: true, bubbles: true }));
      await new Promise(r => setTimeout(r, 450)); // allow debounced tab save
      const snap = window.__mock.getSessionSnapshot();
      const saved = snap.tabs.find(t => t.noteId === 'note-1');
      const unsaved = saved?.unsavedContent ?? '';
      const undoLog = saved?.undoLog ?? '';
      const undoParsed = undoLog ? JSON.parse(undoLog) : null;
      return {
        pass: unsaved.includes('UNSAVED') && !!undoParsed && Array.isArray(undoParsed.undoStack) && undoParsed.undoStack.length >= 1,
        detail: { unsavedHead: unsaved.slice(0, 30), undoStackLen: undoParsed?.undoStack?.length, activeTab: snap.activeTab },
      };
    })()`,
  },
  {
    id: "09_tz_labels",
    title: "Today / Yesterday labels render for local-day buckets",
    body: /* js */ `(async () => {
      await new Promise(r => setTimeout(r, 500));
      const headers = [...document.querySelectorAll('button[data-group-key]')].map(b => b.textContent.trim());
      const hasToday = headers.some(h => h.includes('Today'));
      const hasYesterday = headers.some(h => h.includes('Yesterday'));
      return { pass: hasToday && hasYesterday, detail: { headers } };
    })()`,
  },
];
