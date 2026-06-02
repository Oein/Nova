<script lang="ts">
  import { onDestroy, onMount, tick } from "svelte";
  import { get } from "svelte/store";
  import type { Buffer, BufferChange } from "$lib/editor/buffer/Buffer";
  import type { OpenTab } from "$lib/types";
  import { RopeBuffer } from "$lib/editor/buffer/RopeBuffer";
  import { applyCommand, keymap } from "$lib/editor/commands";
  import { primary, ordered, isEmpty, withPrimary, type CursorState } from "$lib/editor/selection";
  import type { Pos } from "$lib/editor/buffer/Buffer";
  import { metrics } from "$lib/editor/measure";
  import { graphemes } from "$lib/editor/grapheme";
  import { computeWrapStarts, subRowAt, bufferLineAtVisualRow } from "$lib/editor/wrap";
  import { wordAt } from "$lib/editor/wordAt";
  import { saveActive } from "$lib/tabManager";
  import { updateCursor, updateScroll, getTabRuntime } from "$lib/sessionManager";
  import { editorStatus } from "$lib/stores/editorStatus";
  import { revealRequest } from "$lib/stores/reveal";
  import { menuAction } from "$lib/menu";

  export let buffer: Buffer;
  export let tab: OpenTab;

  let viewport: HTMLDivElement;
  let rowsHost: HTMLDivElement;
  let inputEl: HTMLTextAreaElement;

  // Prefer live runtime state (survives tab-switch re-mounts) over the
  // session-restored `tab.initialCursor` which only fires on cold start.
  const rt = getTabRuntime(tab.id);
  const initialPos =
    rt && (rt.cursorLine !== 0 || rt.cursorCol !== 0)
      ? { line: rt.cursorLine, col: rt.cursorCol }
      : tab.initialCursor ?? { line: 0, col: 0 };
  const initialScrollTop = rt && rt.scrollTop !== 0 ? rt.scrollTop : tab.initialScroll;
  let cursor: CursorState = {
    selections: [{ anchor: { ...initialPos }, head: { ...initialPos } }],
    primary: 0,
  };
  let scrollTop = 0;
  let viewportHeight = 0;
  let contentWidth = 400; // updated by onResize; wrap cap for a single visual row
  let lineCount = buffer.lineCount;
  let visibleStart = 0; // first visual row in the mounted window
  let visibleEnd = 0; // exclusive
  // Each "visible line" is one wrapped sub-row of some buffer line.
  let visibleLines: {
    line: number; // buffer line index
    subRow: number; // sub-row within that buffer line (0 = first)
    yRow: number; // absolute visual-row index (for positioning)
    startCol: number; // start col (buffer offset) of this sub-row
    text: string; // sliced line text for this sub-row
    tokens: { text: string; bold: boolean; underline: boolean; strike: boolean }[];
  }[] = [];
  // One gutter entry per visible buffer line (on its sub-row 0).
  let visibleGutter: { line: number; yRow: number }[] = [];
  // Wrap state: for each buffer line, starts[i] = columns where each visual
  // sub-row begins. lineYOffset[i] = cumulative visual rows before buffer line
  // i (prefix sum; length = lineCount + 1). totalVisualRows drives scroll
  // height. Rebuilt on buffer edits, resize, and font zoom.
  let wrapStarts: number[][] = [];
  let lineYOffset: number[] = [0];
  let totalVisualRows = 0;
  let rowHeight = $metrics.rowHeight;
  let chWidth = $metrics.chWidth;
  let cjkWidth = $metrics.cjkWidth;
  let composing = false;
  let compositionText = "";
  // Tab pressed while IME was composing — insert after composition ends.
  let pendingTab = false;

  // Find / Replace state. All held in-component (not a store) because every
  // piece is tightly coupled to this editor's buffer + cursor.
  interface FindMatch {
    line: number;
    startCol: number;
    endCol: number;
  }
  let findOpen = false;
  let replaceVisible = false;
  let findQuery = "";
  let replaceQuery = "";
  let findCaseSensitive = false;
  let findMatches: FindMatch[] = [];
  let activeMatchIdx = -1;
  let findInputEl: HTMLInputElement | null = null;
  let replaceInputEl: HTMLInputElement | null = null;
  // Pixel x-target remembered across consecutive vertical moves, so walking
  // up/down across short lines still returns to the originating column.
  // Reset on any horizontal move, mouse click, or edit.
  let stickyX: number | null = null;

  $: rowHeight = $metrics.rowHeight;
  $: chWidth = $metrics.chWidth;
  $: cjkWidth = $metrics.cjkWidth;
  $: pageLines = Math.max(5, Math.floor(viewportHeight / rowHeight) - 2);
  // Font zoom / gutter-width changes invalidate the wrap cache — one grapheme
  // cell may be wider now, so the column at which a line wraps changes.
  $: {
    chWidth;
    cjkWidth;
    rowHeight;
    contentWidth;
    if (viewport) {
      rebuildWrap();
      recomputeVisible();
    }
  }

  let unsub: (() => void) | null = null;
  // Observe the viewport element so wrap recomputes when the editor's grid
  // cell resizes for reasons other than window resize — e.g. toggling the
  // sidebar (Cmd+B), drag-resizing the sidebar, or the tabbar/bottombar
  // changing height. Without this, `contentWidth` stays frozen at whatever
  // the window was when the editor mounted.
  let viewportRO: ResizeObserver | null = null;
  // Menu-bar actions that target the editor. macOS intercepts the
  // accelerators before the webview sees them, so we can't rely on
  // onKeyDown alone — the menu bridge is the source of truth.
  let lastMenuSeq = -1;
  // Svelte stores deliver the current value synchronously to new
  // subscribers. When this editor mounts mid-session (tab switch
  // remounts via {#key}), the store may already hold a stale event from
  // an earlier menu action — without this guard, switching tabs would
  // re-run the most recent action (e.g. Select All) on the new tab.
  let menuSubReady = false;
  const stopMenuSub = menuAction.subscribe((ev) => {
    if (!menuSubReady) {
      menuSubReady = true;
      if (ev) lastMenuSeq = ev.seq;
      return;
    }
    if (!ev || ev.seq === lastMenuSeq) return;
    lastMenuSeq = ev.seq;
    switch (ev.action) {
      case "file:save":
        saveActive();
        return;
      case "edit:undo":
        dispatch({ type: "undo" });
        return;
      case "edit:redo":
        dispatch({ type: "redo" });
        return;
      case "edit:select-all": {
        const active = document.activeElement as HTMLElement | null;
        if (active && active !== inputEl && (active.tagName === "INPUT" || active.tagName === "TEXTAREA")) {
          (active as HTMLInputElement).select();
        } else {
          dispatch({ type: "select_all" });
        }
        return;
      }
      case "edit:find":
        openFind(false);
        return;
      case "edit:replace":
        openFind(true);
        return;
    }
  });

  // Spotlight (Cmd+K) "open + reveal" requests. A request set before this
  // editor mounts (the common case — the note opens in a fresh tab) is held
  // until onMount, where the viewport and wrap geometry are ready; the
  // subscription only handles requests that arrive while already mounted
  // (revealing in a note that was already open). `revealMatch` clears the
  // store on consume, and an id mismatch is ignored, so requests never replay
  // on an unrelated tab.
  let mounted = false;
  function maybeReveal(req: { id: string; query: string } | null) {
    if (!req || req.id !== tab.id) return;
    revealRequest.set(null);
    void revealMatch(req.query);
  }
  const stopRevealSub = revealRequest.subscribe((req) => {
    if (!mounted) return;
    maybeReveal(req);
  });
  onDestroy(() => {
    if (unsub) unsub();
    viewportRO?.disconnect();
    stopMenuSub();
    stopRevealSub();
    editorStatus.set(null);
  });

  function selectionCharLength(c: CursorState): number {
    const sel = primary(c);
    if (isEmpty(sel)) return 0;
    const { from, to } = ordered(sel);
    if (from.line === to.line) return to.col - from.col;
    let n = buffer.getLine(from.line).length - from.col + 1;
    for (let l = from.line + 1; l < to.line; l++) n += buffer.getLine(l).length + 1;
    n += to.col;
    return n;
  }

  // Per-line non-whitespace count over the selection. Line breaks are counted
  // as whitespace (i.e. excluded), matching how most word-processor "글자 수
  // (공백 제외)" tallies behave.
  function countNonWs(s: string): number {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
      if (!/\s/.test(s[i])) n++;
    }
    return n;
  }

  function selectionCharLengthNoWs(c: CursorState): number {
    const sel = primary(c);
    if (isEmpty(sel)) return 0;
    const { from, to } = ordered(sel);
    if (from.line === to.line) {
      return countNonWs(buffer.getLine(from.line).slice(from.col, to.col));
    }
    let n = countNonWs(buffer.getLine(from.line).slice(from.col));
    for (let l = from.line + 1; l < to.line; l++) n += countNonWs(buffer.getLine(l));
    n += countNonWs(buffer.getLine(to.line).slice(0, to.col));
    return n;
  }

  function publishStatus(c: CursorState) {
    const head = primary(c).head;
    editorStatus.set({
      line: head.line,
      col: head.col,
      selectionChars: selectionCharLength(c),
      selectionCharsNoWs: selectionCharLengthNoWs(c),
    });
  }

  function onBufferChange(c: BufferChange) {
    const prevLen = wrapStarts.length;
    lineCount = buffer.lineCount;
    if (c.kind === "ready" || prevLen === 0) {
      rebuildWrap();
    } else {
      // Incremental: splice only the affected range. We derive the old range
      // length from the length-delta so we don't need to reverse-engineer
      // whether `toLine` is inclusive — the post-splice length is forced to
      // match `buffer.lineCount`.
      const fromLine = c.fromLine;
      const newLineCount = c.newLineCount;
      const oldRangeLen = prevLen - (lineCount - newLineCount);
      if (fromLine < 0 || oldRangeLen < 0 || fromLine + oldRangeLen > prevLen) {
        rebuildWrap();
      } else {
        const next: number[][] = [];
        const m = { chWidth, cjkWidth, tabSize: TABSIZE };
        for (let i = 0; i < newLineCount; i++) {
          next.push(computeWrapStarts(buffer.getLine(fromLine + i), contentWidth, m));
        }
        wrapStarts.splice(fromLine, oldRangeLen, ...next);
        rebuildLineYOffsetFrom(fromLine);
      }
    }
    recomputeVisible();
    // After edits (including replace-all), match highlights must be re-derived
    // so stale col offsets don't point into moved text.
    if (findOpen) recomputeMatches();
  }

  // Full rebuild of wrapStarts + lineYOffset. O(n × graphemes). Called on
  // first mount, on resize / font-zoom (contentWidth changes), and on any
  // buffer event whose incremental bookkeeping looks inconsistent.
  function rebuildWrap() {
    const m = { chWidth, cjkWidth, tabSize: TABSIZE };
    const next: number[][] = new Array(lineCount);
    for (let i = 0; i < lineCount; i++) {
      next[i] = computeWrapStarts(buffer.getLine(i), contentWidth, m);
    }
    wrapStarts = next;
    rebuildLineYOffsetFrom(0);
  }

  function rebuildLineYOffsetFrom(fromLine: number) {
    if (lineYOffset.length !== lineCount + 1) {
      lineYOffset = new Array(lineCount + 1);
      lineYOffset[0] = 0;
    }
    if (fromLine === 0) lineYOffset[0] = 0;
    for (let i = fromLine; i < lineCount; i++) {
      lineYOffset[i + 1] = lineYOffset[i] + wrapStarts[i].length;
    }
    totalVisualRows = lineYOffset[lineCount] ?? 0;
  }

  function recomputeVisible() {
    if (!lineCount || totalVisualRows === 0) {
      visibleLines = [];
      visibleGutter = [];
      visibleStart = 0;
      visibleEnd = 0;
      return;
    }
    const overscan = 10;
    const first = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan);
    const last = Math.min(
      totalVisualRows,
      Math.ceil((scrollTop + viewportHeight) / rowHeight) + overscan,
    );
    visibleStart = first;
    visibleEnd = last;

    const rows: typeof visibleLines = [];
    const gutter: typeof visibleGutter = [];
    let bl = bufferLineAtVisualRow(lineYOffset, first);
    let vr = lineYOffset[bl];
    while (vr < last && bl < lineCount) {
      const starts = wrapStarts[bl];
      const line = buffer.getLine(bl);
      const tokens = tokenizeMarkdownRanges(line);
      gutter.push({ line: bl, yRow: lineYOffset[bl] });
      for (let sr = 0; sr < starts.length; sr++) {
        if (vr >= last) break;
        if (vr >= first) {
          const s = starts[sr];
          const e = sr + 1 < starts.length ? starts[sr + 1] : line.length;
          rows.push({
            line: bl,
            subRow: sr,
            yRow: vr,
            startCol: s,
            text: line.slice(s, e),
            tokens: tokensForSlice(tokens, line, s, e),
          });
        }
        vr++;
      }
      bl++;
    }
    visibleLines = rows;
    visibleGutter = gutter;
  }

  function onScroll() {
    scrollTop = viewport.scrollTop;
    updateScroll(tab.id, scrollTop);
    recomputeVisible();
  }

  function onResize() {
    viewportHeight = viewport.clientHeight;
    contentWidth = Math.max(20, viewport.clientWidth - contentLeft - 8);
    // Synchronous rebuild — the reactive block would run on the next tick,
    // but onMount relies on wrap being ready before it reads back scrollTop.
    rebuildWrap();
    recomputeVisible();
  }

  onMount(async () => {
    unsub = buffer.subscribe(onBufferChange);
    recomputeVisible();
    await tick();
    onResize();
    if (typeof ResizeObserver !== "undefined" && viewport) {
      viewportRO = new ResizeObserver(onResize);
      viewportRO.observe(viewport);
    }
    if (initialScrollTop != null) {
      viewport.scrollTop = initialScrollTop;
      scrollTop = viewport.scrollTop;
      recomputeVisible();
    }
    updateCursor(tab.id, initialPos.line, initialPos.col);
    publishStatus(cursor);
    focusInput();
    // Some webviews (WKWebView) silently reject focus on an off-screen
    // contenteditable before first paint; retry after a frame.
    setTimeout(focusInput, 30);
    // Geometry is ready — consume any pending Spotlight reveal (set before
    // this mount). Overrides the restored scroll above so the match lands in
    // view. Subsequent requests arrive via the live subscription.
    mounted = true;
    maybeReveal(get(revealRequest));
  });

  function focusInput() {
    if (!inputEl) return;
    inputEl.focus({ preventScroll: true });
    // WKWebView occasionally no-ops focus() on first-paint; retry on the
    // next frame if it didn't take.
    requestAnimationFrame(() => {
      if (document.activeElement !== inputEl) {
        inputEl.focus({ preventScroll: true });
      }
    });
  }

  function onInputBlur() {
    // If focus leaves the textarea but stays within the editor area,
    // pull it back so IME keeps working.
    requestAnimationFrame(() => {
      if (viewport && viewport.contains(document.activeElement)) {
        inputEl?.focus({ preventScroll: true });
      }
    });
  }

  // Given a visual row + x-target, resolve to a buffer (line, col). Used for
  // wrap-aware Up/Down / PageUp/PageDown navigation.
  function posAtVisualRow(vr: number, xPx: number): Pos {
    if (lineCount === 0) return { line: 0, col: 0 };
    const bl = bufferLineAtVisualRow(lineYOffset, vr);
    const starts = wrapStarts[bl] ?? [0];
    const sr = Math.max(0, Math.min(starts.length - 1, vr - (lineYOffset[bl] ?? 0)));
    const subStart = starts[sr] ?? 0;
    const line = buffer.getLine(bl);
    const subEnd = sr + 1 < starts.length ? starts[sr + 1] : line.length;
    const slice = line.slice(subStart, subEnd);
    const colInSlice = colFromPx(slice, xPx);
    return { line: bl, col: subStart + colInSlice };
  }

  function doVerticalMove(dir: -1 | 1, extend: boolean, rows: number) {
    const sel = primary(cursor);
    const cv = caretVisual(sel.head.line, sel.head.col);
    if (stickyX == null) stickyX = cv.xPx;
    const rawTarget = cv.yRow + dir * rows;
    let target: Pos;
    if (rawTarget < 0) {
      target = { line: 0, col: 0 };
    } else if (rawTarget >= totalVisualRows) {
      const last = Math.max(0, lineCount - 1);
      target = { line: last, col: buffer.getLine(last).length };
    } else {
      target = posAtVisualRow(rawTarget, stickyX);
    }
    cursor = withPrimary(
      cursor,
      extend ? { anchor: sel.anchor, head: target } : { anchor: target, head: target },
    );
    updateCursor(tab.id, target.line, target.col);
    publishStatus(cursor);
    scrollCaretIntoView();
  }

  function dispatch(cmd: ReturnType<typeof keymap> | null) {
    if (!cmd) return;
    // Up/Down / PageUp/Down: walk by visual rows so wrapped sub-rows are
    // reachable. The generic "move by line" in commands.ts walks by buffer
    // lines, which would skip over sub-rows.
    if (cmd.type === "move" && cmd.by === "line") {
      doVerticalMove(cmd.dir, cmd.extend, 1);
      return;
    }
    if (cmd.type === "page") {
      doVerticalMove(cmd.dir, cmd.extend, cmd.pageLines);
      return;
    }
    cursor = applyCommand({ buffer, cursor }, cmd);
    stickyX = null;
    const head = primary(cursor).head;
    updateCursor(tab.id, head.line, head.col);
    publishStatus(cursor);
    // Edits (insert/paste/backspace/enter) can grow totalVisualRows; a single
    // synchronous scroll gets clamped to the pre-reflow max. The reflow-safe
    // variant re-applies after tick() for any command that might have grown
    // the buffer — overkill for pure cursor moves, but cheap and consistent.
    void scrollCaretIntoViewAfterReflow();
  }

  function onKeyDown(e: KeyboardEvent) {
    if (composing || e.isComposing || e.key === "Process" || e.keyCode === 229) {
      // Tab during IME composition: record it so we can insert after composition
      // ends on platforms that don't re-fire the Tab keydown post-compositionend.
      if (e.key === "Tab") pendingTab = true;
      return;
    }
    // Tab re-fired by the platform after compositionend — or ordinary Tab.
    // Either way, handle it and clear the pending flag (prevents double-insert
    // on platforms that re-fire after we already scheduled it in compositionend).
    if (e.key === "Tab") {
      pendingTab = false;
      e.preventDefault();
      dispatch({ type: "insert", text: "\t" });
      return;
    }
    if ((e.metaKey || e.ctrlKey) && (e.key === "s" || e.key === "S")) {
      e.preventDefault();
      saveActive();
      return;
    }
    // Esc with the find bar open closes it and returns focus to the editor.
    if (findOpen && e.key === "Escape") {
      e.preventDefault();
      closeFind();
      return;
    }
    const cmd = keymap(e, pageLines);
    if (cmd) {
      e.preventDefault();
      dispatch(cmd);
      return;
    }
    // Fallback insert for ASCII-printable keys only — IME-composed text
    // (Korean, CJK, etc.) must flow through compositionstart/update/end.
    if (!e.metaKey && !e.ctrlKey && !e.altKey && e.key.length === 1) {
      const code = e.key.charCodeAt(0);
      if (code >= 32 && code < 127) {
        e.preventDefault();
        dispatch({ type: "insert", text: e.key });
      }
    }
  }

  function onBeforeInput(e: InputEvent) {
    if (composing) return;
    if (e.data != null && e.data.length > 0) {
      e.preventDefault();
      dispatch({ type: "insert", text: e.data });
    }
  }

  function onInput() {
    if (composing || !inputEl) return;
    // Safety net: pull any text the browser wrote into the textarea
    // (e.g., because beforeinput didn't fire or a key after composition
    // landed there) into our buffer.
    const text = inputEl.value;
    if (text) {
      inputEl.value = "";
      dispatch({ type: "insert", text });
    }
  }

  function onCompositionStart() {
    composing = true;
    compositionText = "";
    // Selection-replace semantics: drop the selected text at the moment IME
    // composition begins, so the preedit appears in place of the selection
    // rather than floating next to it. If the user cancels composition
    // (Escape), the deletion is recoverable via Cmd+Z.
    const sel = primary(cursor);
    if (!isEmpty(sel) && buffer.editable) {
      const { from, to } = ordered(sel);
      buffer.applyEdit({ kind: "delete", from, to });
      cursor = withPrimary(cursor, { anchor: from, head: from });
      stickyX = null;
      updateCursor(tab.id, from.line, from.col);
      publishStatus(cursor);
    }
  }
  function onCompositionUpdate(e: CompositionEvent) {
    compositionText = e.data ?? "";
  }
  function onCompositionEnd(e: CompositionEvent) {
    composing = false;
    compositionText = "";
    // Prefer textarea.value over e.data — WKWebView sometimes fires
    // compositionend with empty e.data while the final text is already in
    // the textarea.
    const text = (inputEl?.value ?? "") || (e.data ?? "");
    if (inputEl) inputEl.value = "";
    if (text) dispatch({ type: "insert", text });
    if (pendingTab) {
      // On platforms that re-fire a Tab keydown after compositionend, the
      // keydown handler will clear pendingTab and insert the tab there.
      // On platforms that don't re-fire (Tab is only seen during composition),
      // we insert it here after giving the event loop one turn to catch any
      // re-fired keydown.
      requestAnimationFrame(() => {
        if (pendingTab) {
          pendingTab = false;
          dispatch({ type: "insert", text: "\t" });
        }
      });
    }
  }

  function onPaste(e: ClipboardEvent) {
    const text = e.clipboardData?.getData("text/plain");
    if (text) {
      e.preventDefault();
      dispatch({ type: "insert", text });
    }
  }

  function onCopy(e: ClipboardEvent) {
    const sel = primary(cursor);
    if (isEmpty(sel)) return;
    const { from, to } = ordered(sel);
    let text = "";
    if (buffer instanceof RopeBuffer) text = buffer.sliceText(from, to);
    else return; // no copy from paged for now
    e.clipboardData?.setData("text/plain", text);
    e.preventDefault();
  }

  function onCut(e: ClipboardEvent) {
    onCopy(e);
    dispatch({ type: "backspace" });
  }

  function onMouseDown(e: MouseEvent) {
    const pos = hitTest(e);
    if (!pos) return;
    stickyX = null;
    // Shift+click extends the selection from the existing anchor to the
    // clicked position — matches macOS / Sublime / VS Code. The subsequent
    // drag (if any) keeps the same anchor, so the user can rubber-band the
    // head around while holding shift.
    const existingAnchor = primary(cursor).anchor;
    const anchor = e.shiftKey ? existingAnchor : pos;
    const head = pos;
    cursor = { selections: [{ anchor, head }], primary: 0 };
    publishStatus(cursor);
    updateCursor(tab.id, head.line, head.col);
    focusInput();
    const move = (ev: MouseEvent) => {
      const p2 = hitTest(ev);
      if (!p2) return;
      cursor = { ...cursor, selections: [{ anchor, head: p2 }] };
      publishStatus(cursor);
      updateCursor(tab.id, p2.line, p2.col);
    };
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  }

  // True if the pointer is over the gutter column (line-number rail).
  // Distinguishes "double-click to select line" (gutter) from
  // "double-click to select word" (text area).
  function isInGutter(e: MouseEvent): boolean {
    const rect = viewport.getBoundingClientRect();
    return e.clientX - rect.left < gutterWidth;
  }

  function selectRange(from: Pos, to: Pos) {
    cursor = { selections: [{ anchor: from, head: to }], primary: 0 };
    stickyX = null;
    publishStatus(cursor);
    updateCursor(tab.id, to.line, to.col);
    focusInput();
  }

  function onDblClick(e: MouseEvent) {
    const pos = hitTest(e);
    if (!pos) return;
    if (isInGutter(e)) {
      // Select the whole buffer line. Include the trailing newline (by
      // extending to col 0 of the next line) so copy/cut captures it —
      // except on the very last line, which has no newline to grab.
      const lineLen = buffer.getLine(pos.line).length;
      const from: Pos = { line: pos.line, col: 0 };
      const to: Pos =
        pos.line + 1 < lineCount
          ? { line: pos.line + 1, col: 0 }
          : { line: pos.line, col: lineLen };
      selectRange(from, to);
      e.preventDefault();
      return;
    }
    const line = buffer.getLine(pos.line);
    const span = wordAt(line, pos.col);
    if (span.start === span.end) return;
    selectRange(
      { line: pos.line, col: span.start },
      { line: pos.line, col: span.end },
    );
    e.preventDefault();
  }

  const TABSIZE = 4;

  // True when the char is fullwidth (CJK / Hangul / Kana / fullwidth forms).
  // Fullwidth chars are rendered at `cjkWidth`; everything else at `chWidth`.
  function isFullwidth(ch: string): boolean {
    const code = ch.charCodeAt(0);
    if (code < 0x1100) return false;
    return (
      (code >= 0x1100 && code <= 0x115f) ||
      (code >= 0x2e80 && code <= 0x303e) ||
      (code >= 0x3041 && code <= 0x33ff) ||
      (code >= 0x3400 && code <= 0x4dbf) ||
      (code >= 0x4e00 && code <= 0x9fff) ||
      (code >= 0xa000 && code <= 0xa4cf) ||
      (code >= 0xac00 && code <= 0xd7a3) ||
      (code >= 0xf900 && code <= 0xfaff) ||
      (code >= 0xfe30 && code <= 0xfe4f) ||
      (code >= 0xff00 && code <= 0xff60) ||
      (code >= 0xffe0 && code <= 0xffe6)
    );
  }

  function charPx(ch: string): number {
    return isFullwidth(ch) ? cjkWidth : chWidth;
  }

  // Width of a single grapheme cluster. Any multi-code-unit cluster (surrogate
  // pair, VS-16 sequence like ⬛️, ZWJ emoji, regional-indicator flag,
  // combining marks) renders roughly fullwidth in mono fonts.
  function graphemePx(g: string): number {
    if (g.length > 1) return cjkWidth;
    return charPx(g);
  }

  // Pixel x-offset from start of the line up to `col` (exclusive).
  // `col` is assumed to sit on a grapheme boundary; if it doesn't, we stop at
  // the last boundary ≤ col, which is the safest visual approximation.
  function visualPx(line: string, col: number): number {
    const tabPx = TABSIZE * chWidth;
    const limit = Math.min(col, line.length);
    let x = 0;
    for (const g of graphemes(line)) {
      if (g.col >= limit) break;
      if (g.text === "\t") {
        x = (Math.floor(x / tabPx) + 1) * tabPx;
      } else {
        x += graphemePx(g.text);
      }
    }
    return x;
  }

  function colFromPx(line: string, px: number): number {
    const tabPx = TABSIZE * chWidth;
    let x = 0;
    for (const g of graphemes(line)) {
      const cw =
        g.text === "\t" ? (Math.floor(x / tabPx) + 1) * tabPx - x : graphemePx(g.text);
      if (px < x + cw) {
        return px - x >= cw / 2 ? g.col + g.text.length : g.col;
      }
      x += cw;
    }
    return line.length;
  }

  function hitTest(e: MouseEvent): { line: number; col: number } | null {
    // rowsHost (.gutter) lives inside the scrolling viewport, so its
    // bounding rect already moves with scroll — e.clientY - rect.top
    // IS the content-space y. Adding viewport.scrollTop would double-count.
    const rect = rowsHost.getBoundingClientRect();
    const y = e.clientY - rect.top;
    const x = e.clientX - rect.left - contentLeft;
    if (totalVisualRows === 0 || lineCount === 0) return { line: 0, col: 0 };
    const vr = Math.max(0, Math.min(totalVisualRows - 1, Math.floor(y / rowHeight)));
    const bl = bufferLineAtVisualRow(lineYOffset, vr);
    const starts = wrapStarts[bl] ?? [0];
    const sr = vr - lineYOffset[bl];
    const subStart = starts[sr] ?? 0;
    const lineText = buffer.getLine(bl);
    const subEnd = sr + 1 < starts.length ? starts[sr + 1] : lineText.length;
    const slice = lineText.slice(subStart, subEnd);
    const colInSlice = colFromPx(slice, Math.max(0, x));
    return { line: bl, col: subStart + colInSlice };
  }

  // Map a buffer (line, col) to a visual row index + x-offset within that row.
  // With wrap, one buffer line spans one or more sub-rows — the caret sits on
  // the sub-row whose starting col is the largest ≤ col.
  function caretVisual(lineIdx: number, col: number): { yRow: number; xPx: number } {
    const starts = wrapStarts[lineIdx] ?? [0];
    const sr = subRowAt(starts, col);
    const subStart = starts[sr];
    const slice = buffer.getLine(lineIdx).slice(subStart, col);
    return {
      yRow: (lineYOffset[lineIdx] ?? 0) + sr,
      xPx: visualPx(slice, slice.length),
    };
  }

  function scrollCaretIntoView() {
    const head = primary(cursor).head;
    const cv = caretVisual(head.line, head.col);
    const y = cv.yRow * rowHeight;
    if (y < viewport.scrollTop) viewport.scrollTop = y;
    else if (y + rowHeight > viewport.scrollTop + viewport.clientHeight) {
      viewport.scrollTop = y + rowHeight - viewport.clientHeight;
    }
    // Horizontal scroll is unused under wrap; only nudge when a single grapheme
    // is wider than the viewport (pathological narrow width).
    if (cv.xPx + chWidth > viewport.clientWidth - contentLeft) {
      viewport.scrollLeft = cv.xPx + chWidth - viewport.clientWidth + contentLeft;
    } else {
      viewport.scrollLeft = 0;
    }
  }

  // Center a (line, col) in the viewport. Unlike scrollCaretIntoView — which
  // only nudges the minimum amount — a jump from search should land the match
  // comfortably in view, so we center it (clamped to the scrollable range).
  // `sideHeight` (totalVisualRows * rowHeight) is used instead of the DOM's
  // scrollHeight so this is correct even before Svelte reflows the spacer.
  function scrollPosCentered(line: number, col: number) {
    if (!viewport) return;
    const cv = caretVisual(line, col);
    const y = cv.yRow * rowHeight;
    const maxScroll = Math.max(0, totalVisualRows * rowHeight - viewport.clientHeight);
    const target = y - viewport.clientHeight / 2 + rowHeight / 2;
    viewport.scrollTop = Math.max(0, Math.min(target, maxScroll));
    scrollTop = viewport.scrollTop;
    recomputeVisible();
  }

  // Jump to and select the first occurrence of `query` (case-insensitive) in
  // the buffer. Driven by the Spotlight (Cmd+K) reveal request so opening a
  // search hit scrolls to the matched text. Matching is per-line — the same
  // basis as Find/Replace's recomputeMatches — so multi-line queries won't
  // resolve, which is fine for the single-token queries search produces.
  async function revealMatch(query: string) {
    const q = query.toLowerCase();
    if (!q) return;
    let found: { line: number; startCol: number } | null = null;
    for (let l = 0; l < buffer.lineCount; l++) {
      const idx = buffer.getLine(l).toLowerCase().indexOf(q);
      if (idx !== -1) {
        found = { line: l, startCol: idx };
        break;
      }
    }
    if (!found) return;
    const from = { line: found.line, col: found.startCol };
    const to = { line: found.line, col: found.startCol + query.length };
    cursor = withPrimary(cursor, { anchor: from, head: to });
    publishStatus(cursor);
    updateCursor(tab.id, to.line, to.col);
    // Wait for any pending reflow (e.g. fresh mount) so caretVisual and the
    // scroll range are accurate, then center the match and focus the editor.
    await tick();
    scrollPosCentered(found.line, found.startCol);
    focusInput();
  }

  // After an edit, Svelte hasn't yet resized the scroll container's
  // `sideHeight`. Two distinct hazards to handle:
  //   - INSERT/paste grows sideHeight: the first scrollCaretIntoView gets
  //     clamped to the OLD max when the caret lands past the old end. Re-apply
  //     after tick() once the DOM reflects the new totalVisualRows.
  //   - DELETE shrinks sideHeight: the browser auto-clamps scrollTop down to
  //     the new max if our current scrollTop exceeded it. The visual effect
  //     is "scroll jumped up" — annoying when the caret was visible all along.
  //     We snapshot scrollTop before reflow and restore it if it still fits.
  async function scrollCaretIntoViewAfterReflow() {
    const snapshot = viewport ? viewport.scrollTop : 0;
    scrollCaretIntoView();
    await tick();
    // Try to keep the user's view stable if the snapshot is still a valid
    // scroll position AND the caret is visible at that scroll position.
    // Otherwise fall through to scrollCaretIntoView, which only nudges when
    // the caret is actually off-screen.
    if (viewport) {
      const maxScroll = Math.max(0, viewport.scrollHeight - viewport.clientHeight);
      if (snapshot <= maxScroll) {
        const head = primary(cursor).head;
        const cv = caretVisual(head.line, head.col);
        const y = cv.yRow * rowHeight;
        const visibleAtSnapshot =
          y >= snapshot && y + rowHeight <= snapshot + viewport.clientHeight;
        if (visibleAtSnapshot) viewport.scrollTop = snapshot;
      }
    }
    scrollCaretIntoView();
  }

  // Carries reactive deps through so `$:` blocks recompute when metrics change.
  function pin<T>(value: T, ..._deps: unknown[]): T {
    return value;
  }

  $: caret = pin(
    caretVisual(primary(cursor).head.line, primary(cursor).head.col),
    chWidth,
    cjkWidth,
    totalVisualRows,
    lineYOffset,
  );

  // Pixel x-position at the END of the preedit text, starting from startX.
  // Used to place the hidden textarea at the IME cursor (after preedit), so
  // the candidate window appears in the right place during composition.
  function preeditEndX(startX: number, text: string): number {
    if (!text) return startX;
    const tabPx = TABSIZE * chWidth;
    let x = startX;
    for (const g of graphemes(text)) {
      if (g.text === "\t") {
        x = (Math.floor(x / tabPx) + 1) * tabPx;
      } else {
        x += graphemePx(g.text);
      }
    }
    return x;
  }

  // During composition, position the hidden input at the end of the preedit so
  // the IME candidate window appears after the composing text, not before it.
  $: inputLeft = composing ? preeditEndX(caret.xPx, compositionText) : caret.xPx;

  $: spanList = pin(computeSpans(cursor, visibleStart, visibleEnd), chWidth, cjkWidth);

  // Emit one selection rect per wrapped sub-row inside the visible window.
  // Sub-rows that fall between the start and end buffer lines are filled to
  // their trailing edge (plus one chWidth) so the "selection continues here"
  // ribbon is visible even on blank tail rows.
  function computeSpans(
    c: CursorState,
    firstVR: number,
    lastVR: number,
  ): { l: number; x0: number; x1: number }[] {
    if (isEmpty(primary(c))) return [];
    const { from: a, to: b } = ordered(primary(c));
    const out: { l: number; x0: number; x1: number }[] = [];
    for (let bl = a.line; bl <= b.line; bl++) {
      const starts = wrapStarts[bl];
      if (!starts) continue;
      const line = buffer.getLine(bl);
      for (let sr = 0; sr < starts.length; sr++) {
        const vr = (lineYOffset[bl] ?? 0) + sr;
        if (vr < firstVR || vr >= lastVR) continue;
        const subStart = starts[sr];
        const subEnd = sr + 1 < starts.length ? starts[sr + 1] : line.length;
        const lineSelStart = bl === a.line ? a.col : subStart;
        const lineSelEnd = bl === b.line ? b.col : subEnd;
        const s0 = Math.max(subStart, lineSelStart);
        const s1 = Math.min(subEnd, Math.max(subStart, lineSelEnd));
        // Draw a small trailing ribbon when the selection wraps past this
        // sub-row (either to the next sub-row of the same line or to the next
        // buffer line).
        const ribbon =
          (bl < b.line && sr === starts.length - 1) || (bl === b.line && b.col > subEnd);
        if (s1 <= s0 && !ribbon) continue;
        const x0 = visualPx(line.slice(subStart, s0), s0 - subStart);
        const base = visualPx(line.slice(subStart, s1), s1 - subStart);
        const x1 = ribbon ? base + chWidth : base;
        if (x1 > x0) out.push({ l: vr, x0, x1 });
      }
    }
    return out;
  }

  $: sideHeight = totalVisualRows * rowHeight;
  // Gutter width scales with line-number digit count and current char width so
  // big fonts don't overflow the fixed 52 px gutter into the text area.
  $: gutterDigits = Math.max(2, String(Math.max(1, lineCount)).length);
  $: gutterWidth = Math.ceil(gutterDigits * chWidth + 24);
  $: contentLeft = gutterWidth + 4;

  type MdTokenRange = {
    startCol: number;
    endCol: number;
    bold: boolean;
    underline: boolean;
    strike: boolean;
  };
  type MdToken = { text: string; bold: boolean; underline: boolean; strike: boolean };

  // Tokenize a full buffer line into column-ranged styled tokens. Running the
  // tokenizer on the whole line (rather than per sub-row) keeps **bold** and
  // heading styles consistent across a soft-wrap boundary.
  function tokenizeMarkdownRanges(line: string): MdTokenRange[] {
    const headingBold = /^#{1,3} /.test(line);
    const out: MdTokenRange[] = [];
    const n = line.length;
    let i = 0;
    let plainStart = -1;
    const flushPlain = (end: number) => {
      if (plainStart >= 0 && plainStart < end) {
        out.push({
          startCol: plainStart,
          endCol: end,
          bold: headingBold,
          underline: false,
          strike: false,
        });
      }
      plainStart = -1;
    };
    const inline = [
      ["**", "bold"],
      ["__", "underline"],
      ["~~", "strike"],
    ] as const;
    while (i < n) {
      let opened = false;
      for (const [delim, kind] of inline) {
        if (line.startsWith(delim, i)) {
          const closer = line.indexOf(delim, i + 2);
          if (closer !== -1 && closer > i + 2) {
            flushPlain(i);
            out.push({
              startCol: i,
              endCol: closer + 2,
              bold: headingBold || kind === "bold",
              underline: kind === "underline",
              strike: kind === "strike",
            });
            i = closer + 2;
            opened = true;
            break;
          }
        }
      }
      if (opened) continue;
      if (plainStart < 0) plainStart = i;
      i++;
    }
    flushPlain(n);
    return out;
  }

  // ────────────── Find / Replace ──────────────

  // Open the find bar. If `withReplace` is true, also show the replace row.
  // Pre-fills the query from any single-line selection (matches Sublime / VS
  // Code — if you select a word and hit Cmd+F, the selection becomes the
  // query). Re-opening when already open just re-focuses the input.
  async function openFind(withReplace: boolean) {
    findOpen = true;
    if (withReplace) replaceVisible = true;
    const sel = primary(cursor);
    if (!isEmpty(sel) && sel.anchor.line === sel.head.line) {
      const { from, to } = ordered(sel);
      const slice = buffer.getLine(from.line).slice(from.col, to.col);
      if (slice.length > 0) findQuery = slice;
    }
    recomputeMatches();
    await tick();
    findInputEl?.focus();
    findInputEl?.select();
  }

  function closeFind() {
    findOpen = false;
    replaceVisible = false;
    findMatches = [];
    activeMatchIdx = -1;
    focusInput();
  }

  // Re-scan the whole buffer for occurrences of `findQuery`. Cheap enough on
  // small-to-medium notes (`indexOf` is native and linear). For massive files
  // this could be made incremental, but v1 keeps it simple.
  function recomputeMatches() {
    if (!findOpen || !findQuery) {
      findMatches = [];
      activeMatchIdx = -1;
      return;
    }
    const q = findCaseSensitive ? findQuery : findQuery.toLowerCase();
    const out: FindMatch[] = [];
    for (let l = 0; l < buffer.lineCount; l++) {
      const raw = buffer.getLine(l);
      const hay = findCaseSensitive ? raw : raw.toLowerCase();
      let i = 0;
      while (i <= hay.length - q.length) {
        const idx = hay.indexOf(q, i);
        if (idx === -1) break;
        out.push({ line: l, startCol: idx, endCol: idx + q.length });
        i = idx + Math.max(1, q.length); // max(1,…) guards against empty query
      }
    }
    findMatches = out;
    // Pick the first match at or after the current cursor head. Keeps "Cmd+F
    // then Enter" feeling natural — you jump forward from where you are.
    if (out.length === 0) {
      activeMatchIdx = -1;
      return;
    }
    const head = primary(cursor).head;
    const idx = out.findIndex(
      (m) => m.line > head.line || (m.line === head.line && m.startCol >= head.col),
    );
    activeMatchIdx = idx === -1 ? 0 : idx;
  }

  function gotoMatch(idx: number) {
    if (findMatches.length === 0) return;
    // Wrap around at both ends — Enter from the last match lands on the first.
    const n = findMatches.length;
    const wrapped = ((idx % n) + n) % n;
    activeMatchIdx = wrapped;
    const m = findMatches[wrapped];
    const from = { line: m.line, col: m.startCol };
    const to = { line: m.line, col: m.endCol };
    cursor = withPrimary(cursor, { anchor: from, head: to });
    publishStatus(cursor);
    updateCursor(tab.id, to.line, to.col);
    // Scroll target is the match's first visible row. We don't reuse
    // scrollCaretIntoView because that aims at the caret (which is the head
    // after this update) — same line, so equivalent here.
    scrollCaretIntoView();
  }

  function findNext() {
    if (findMatches.length === 0) return;
    gotoMatch(activeMatchIdx + 1);
  }

  function findPrev() {
    if (findMatches.length === 0) return;
    gotoMatch(activeMatchIdx - 1);
  }

  function replaceCurrent() {
    if (!buffer.editable) return;
    if (activeMatchIdx < 0 || activeMatchIdx >= findMatches.length) return;
    const m = findMatches[activeMatchIdx];
    const from = { line: m.line, col: m.startCol };
    const to = { line: m.line, col: m.endCol };
    buffer.applyEdit({ kind: "delete", from, to });
    if (replaceQuery.length > 0) {
      buffer.applyEdit({ kind: "insert", at: from, text: replaceQuery });
    }
    // Land the cursor at the end of the replacement so the next Enter on the
    // find input advances to the NEXT match past it. onBufferChange will
    // re-run recomputeMatches and pick the first match ≥ current cursor.
    const after = advancePosByText(from, replaceQuery);
    cursor = withPrimary(cursor, { anchor: after, head: after });
    publishStatus(cursor);
    updateCursor(tab.id, after.line, after.col);
  }

  function replaceAll() {
    if (!buffer.editable) return;
    if (findMatches.length === 0) return;
    // Iterate matches in reverse order so earlier-match column offsets stay
    // valid while we mutate later-match locations first. All on the same
    // buffer — edits flush through onBufferChange and trigger re-scan after.
    for (let i = findMatches.length - 1; i >= 0; i--) {
      const m = findMatches[i];
      const from = { line: m.line, col: m.startCol };
      const to = { line: m.line, col: m.endCol };
      buffer.applyEdit({ kind: "delete", from, to });
      if (replaceQuery.length > 0) {
        buffer.applyEdit({ kind: "insert", at: from, text: replaceQuery });
      }
    }
    // Place the caret at the end of the last (now-first) replacement so the
    // user has a visual anchor. The re-scan will clear findMatches afterwards.
    publishStatus(cursor);
  }

  // Same shape as advancePosByText in commands.ts — kept local so we don't
  // import private helpers across module boundaries.
  function advancePosByText(p: Pos, text: string): Pos {
    if (!text.includes("\n")) return { line: p.line, col: p.col + text.length };
    const lines = text.split("\n");
    return { line: p.line + lines.length - 1, col: lines[lines.length - 1].length };
  }

  // Keystroke handling while focus is in the find / replace inputs. The
  // editor-level onKeyDown doesn't see these because focus is on the input.
  function onFindKeyDown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      closeFind();
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (e.shiftKey) findPrev();
      else findNext();
    }
  }
  function onReplaceKeyDown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      closeFind();
    } else if (e.key === "Enter") {
      e.preventDefault();
      // Replace-and-advance: the common "go through every match" flow.
      replaceCurrent();
    }
  }

  // Re-scan when query / case-sensitivity changes AND preview-select the
  // active match so Enter "advances from what you see." This path is ONLY for
  // user actions in the find bar — buffer edits that happen elsewhere call
  // recomputeMatches directly (no auto-navigate) so typing in the editor
  // doesn't hijack the cursor into a match.
  $: if (findOpen) {
    findQuery;
    findCaseSensitive;
    recomputeMatches();
    if (activeMatchIdx >= 0) gotoMatch(activeMatchIdx);
  }

  // Compute match rectangles for the visible viewport window. Mirrors the
  // shape of computeSpans for selections. Active match uses a distinct class
  // so it pops visually.
  $: findSpans = pin(
    computeFindSpans(findMatches, visibleStart, visibleEnd),
    chWidth,
    cjkWidth,
    wrapStarts,
  );
  $: activeFindSpans = pin(
    activeMatchIdx >= 0 && activeMatchIdx < findMatches.length
      ? computeFindSpans([findMatches[activeMatchIdx]], visibleStart, visibleEnd)
      : [],
    chWidth,
    cjkWidth,
    wrapStarts,
  );

  function computeFindSpans(
    matches: FindMatch[],
    firstVR: number,
    lastVR: number,
  ): { l: number; x0: number; x1: number; key: string }[] {
    const out: { l: number; x0: number; x1: number; key: string }[] = [];
    for (let mi = 0; mi < matches.length; mi++) {
      const m = matches[mi];
      const starts = wrapStarts[m.line];
      if (!starts) continue;
      const line = buffer.getLine(m.line);
      for (let sr = 0; sr < starts.length; sr++) {
        const vr = (lineYOffset[m.line] ?? 0) + sr;
        if (vr < firstVR || vr >= lastVR) continue;
        const subStart = starts[sr];
        const subEnd = sr + 1 < starts.length ? starts[sr + 1] : line.length;
        const s0 = Math.max(subStart, m.startCol);
        const s1 = Math.min(subEnd, m.endCol);
        if (s1 <= s0) continue;
        const x0 = visualPx(line.slice(subStart, s0), s0 - subStart);
        const x1 = visualPx(line.slice(subStart, s1), s1 - subStart);
        out.push({ l: vr, x0, x1, key: `${mi}:${vr}:${x0}` });
      }
    }
    return out;
  }

  // Clip the full-line token list to a [subStart, subEnd) window and slice
  // each token's text accordingly. Produces the spans rendered into one
  // wrapped sub-row.
  function tokensForSlice(
    tokens: MdTokenRange[],
    line: string,
    subStart: number,
    subEnd: number,
  ): MdToken[] {
    const out: MdToken[] = [];
    for (const tk of tokens) {
      const s = Math.max(tk.startCol, subStart);
      const e = Math.min(tk.endCol, subEnd);
      if (s >= e) continue;
      out.push({
        text: line.slice(s, e),
        bold: tk.bold,
        underline: tk.underline,
        strike: tk.strike,
      });
    }
    return out;
  }

  // Split a MdToken[] at a character offset within the concatenated token text.
  function splitTokensAt(
    tokens: MdToken[],
    at: number,
  ): { before: MdToken[]; after: MdToken[] } {
    const before: MdToken[] = [];
    const after: MdToken[] = [];
    let offset = 0;
    for (const t of tokens) {
      const end = offset + t.text.length;
      if (end <= at) {
        before.push(t);
      } else if (offset >= at) {
        after.push(t);
      } else {
        if (at > offset) before.push({ ...t, text: t.text.slice(0, at - offset) });
        if (end > at) after.push({ ...t, text: t.text.slice(at - offset) });
      }
      offset = end;
    }
    return { before, after };
  }
</script>

<svelte:window on:resize={onResize} />

<!-- svelte-ignore a11y-no-static-element-interactions -->
<div
  class="editor"
  bind:this={viewport}
  on:scroll={onScroll}
  on:mousedown={onMouseDown}
  on:dblclick={onDblClick}
  on:keydown={onKeyDown}
  on:paste={onPaste}
  on:copy={onCopy}
  on:cut={onCut}
  data-testid="editor"
>
  <div class="canvas" style="height: {sideHeight}px">
    <div
      class="gutter"
      bind:this={rowsHost}
      style="height: {sideHeight}px; width: {gutterWidth}px"
    >
      {#each visibleGutter as g (g.line)}
        <div
          class="gutter-line"
          style="top: {g.yRow * rowHeight}px; height: {rowHeight}px; width: {gutterWidth - 12}px"
        >
          {g.line + 1}
        </div>
      {/each}
    </div>
    <div class="rows" style="height: {sideHeight}px; left: {contentLeft}px">
      {#each spanList as s (s.l + ":" + s.x0 + ":" + s.x1)}
        <div
          class="selection"
          style="top: {s.l * rowHeight}px; height: {rowHeight}px; left: {s.x0}px; width: {s.x1 - s.x0}px"
        />
      {/each}
      {#each findSpans as s (s.key)}
        <div
          class="match"
          style="top: {s.l * rowHeight}px; height: {rowHeight}px; left: {s.x0}px; width: {s.x1 - s.x0}px"
        />
      {/each}
      {#each activeFindSpans as s (s.key)}
        <div
          class="match-active"
          style="top: {s.l * rowHeight}px; height: {rowHeight}px; left: {s.x0}px; width: {s.x1 - s.x0}px"
        />
      {/each}
      {#each visibleLines as r (r.yRow)}
        {@const head = primary(cursor).head}
        {@const isPreeditRow = composing && r.line === head.line && head.col >= r.startCol && head.col <= r.startCol + r.text.length}
        <div class="row" style="top: {r.yRow * rowHeight}px; height: {rowHeight}px">
          {#if isPreeditRow}
            {@const at = head.col - r.startCol}
            {@const split = splitTokensAt(r.tokens, at)}
            {#each split.before as t, ti (ti)}<span
                class:b={t.bold}
                class:u={t.underline}
                class:s={t.strike}>{t.text}</span>{/each}<span class="preedit-inline">{compositionText}</span>{#each split.after as t, ti (ti)}<span
                class:b={t.bold}
                class:u={t.underline}
                class:s={t.strike}>{t.text}</span>{/each}
          {:else if r.text}
            {#each r.tokens as t, ti (ti)}<span
                class:b={t.bold}
                class:u={t.underline}
                class:s={t.strike}>{t.text}</span>{/each}
          {:else}
            {"\u200b"}
          {/if}
        </div>
      {/each}
      <div
        class="caret"
        style="top: {caret.yRow * rowHeight}px; height: {rowHeight}px; left: {caret.xPx}px"
      />
      <textarea
        bind:this={inputEl}
        class="hidden-input"
        aria-label="Editor input"
        autocapitalize="off"
        autocomplete="off"
        autocorrect="off"
        spellcheck="false"
        on:beforeinput={onBeforeInput}
        on:input={onInput}
        on:compositionstart={onCompositionStart}
        on:compositionupdate={onCompositionUpdate}
        on:compositionend={onCompositionEnd}
        on:paste|stopPropagation={onPaste}
        on:copy|stopPropagation={onCopy}
        on:cut|stopPropagation={onCut}
        on:blur={onInputBlur}
        style="top: {caret.yRow * rowHeight}px; left: {inputLeft}px; height: {rowHeight}px"
      ></textarea>
    </div>
  </div>

  {#if !buffer.editable}
    <div class="readonly-badge">Read-only (large file)</div>
  {/if}
</div>

{#if findOpen}
  <!-- Overlay, positioned by .editor-host (Editor's parent). Not inside the
       scroll container so scrolling the buffer doesn't push the bar away. -->
  <div class="find-bar" role="dialog" aria-label="Find and replace">
    <div class="find-row">
      <input
        bind:this={findInputEl}
        bind:value={findQuery}
        on:keydown={onFindKeyDown}
        class="find-input"
        placeholder="Find"
        aria-label="Find"
        spellcheck="false"
      />
      <span class="find-count" aria-live="polite">
        {#if findQuery === ""}
          &nbsp;
        {:else if findMatches.length === 0}
          No matches
        {:else}
          {activeMatchIdx + 1} / {findMatches.length}
        {/if}
      </span>
      <button
        class="find-btn"
        class:active={findCaseSensitive}
        on:click={() => (findCaseSensitive = !findCaseSensitive)}
        title="Match case"
        aria-label="Match case"
        aria-pressed={findCaseSensitive}
      >Aa</button>
      <button
        class="find-btn"
        on:click={findPrev}
        disabled={findMatches.length === 0}
        title="Previous (Shift+Enter)"
        aria-label="Previous match"
      >‹</button>
      <button
        class="find-btn"
        on:click={findNext}
        disabled={findMatches.length === 0}
        title="Next (Enter)"
        aria-label="Next match"
      >›</button>
      <button
        class="find-btn"
        class:active={replaceVisible}
        on:click={() => (replaceVisible = !replaceVisible)}
        title="Toggle replace"
        aria-label="Toggle replace"
        aria-pressed={replaceVisible}
      >⇅</button>
      <button
        class="find-btn"
        on:click={closeFind}
        title="Close (Esc)"
        aria-label="Close find"
      >✕</button>
    </div>
    {#if replaceVisible}
      <div class="find-row">
        <input
          bind:this={replaceInputEl}
          bind:value={replaceQuery}
          on:keydown={onReplaceKeyDown}
          class="find-input"
          placeholder="Replace"
          aria-label="Replace"
          spellcheck="false"
          disabled={!buffer.editable}
        />
        <button
          class="find-btn wide"
          on:click={replaceCurrent}
          disabled={findMatches.length === 0 || !buffer.editable}
          title="Replace"
        >Replace</button>
        <button
          class="find-btn wide"
          on:click={replaceAll}
          disabled={findMatches.length === 0 || !buffer.editable}
          title="Replace all"
        >All</button>
      </div>
    {/if}
  </div>
{/if}

<style>
  .editor {
    position: absolute;
    inset: 0;
    overflow-x: hidden;
    overflow-y: auto;
    font-family: var(--font-mono);
    font-size: var(--editor-font-size, 13px);
    background: var(--bg-0);
    color: var(--fg-0);
    white-space: pre;
    /* I-beam over the whole editing surface — .gutter overrides below so
       the line-number rail keeps the arrow (and advertises itself as a
       click target for line selection). */
    cursor: text;
  }
  .canvas {
    position: relative;
    min-width: 100%;
    min-height: 100%;
  }
  .gutter {
    position: absolute;
    top: 0;
    left: 0;
    background: var(--bg-1);
    color: var(--fg-2);
    border-right: 1px solid var(--bg-2);
    user-select: none;
    cursor: default;
  }
  .gutter-line {
    position: absolute;
    right: 10px;
    text-align: right;
    font-size: calc(var(--editor-font-size, 13px) - 2px);
    line-height: var(--editor-row-height, 20px);
  }
  .rows {
    position: absolute;
    top: 0;
    right: 0;
    min-height: 100%;
  }
  .row {
    position: absolute;
    left: 0;
    line-height: var(--editor-row-height, 20px);
    white-space: pre;
    tab-size: 4;
    -moz-tab-size: 4;
  }
  .row .b {
    font-weight: 700;
  }
  .row .u:not(.s) {
    text-decoration: underline;
  }
  .row .s:not(.u) {
    text-decoration: line-through;
  }
  .row .u.s {
    text-decoration: underline line-through;
  }
  .selection {
    position: absolute;
    background: rgba(122, 162, 247, 0.25);
    pointer-events: none;
  }
  .match {
    position: absolute;
    background: rgba(240, 200, 0, 0.28);
    outline: 1px solid rgba(240, 200, 0, 0.55);
    pointer-events: none;
    box-sizing: border-box;
  }
  .match-active {
    position: absolute;
    background: rgba(255, 140, 0, 0.45);
    outline: 1px solid rgba(255, 140, 0, 0.9);
    pointer-events: none;
    box-sizing: border-box;
  }
  .caret {
    position: absolute;
    width: 1.5px;
    background: var(--fg-0);
    animation: blink 1s steps(2) infinite;
    pointer-events: none;
  }
  @keyframes blink { 50% { opacity: 0; } }
  .preedit-inline {
    color: var(--accent);
    text-decoration: underline;
    pointer-events: none;
  }
  .hidden-input {
    position: absolute;
    width: 1px;
    opacity: 0;
    outline: none;
    border: none;
    padding: 0;
    margin: 0;
    resize: none;
    overflow: hidden;
    caret-color: transparent;
    font-family: var(--font-mono);
    font-size: var(--editor-font-size, 13px);
    line-height: var(--editor-row-height, 20px);
    background: transparent;
    color: transparent;
    white-space: pre;
    /* This textarea is keyboard-only — it relays keys / IME to the buffer
       but the user never aims the mouse at it. Pass mouse through so
       hovering the caret zone still shows the editor's I-beam (WKWebView's
       UA cursor for an opacity-0 textarea otherwise flickers to arrow),
       and so clicks reach the underlying .editor handler without the 1px
       textarea briefly eating them. Focus is set programmatically via
       focusInput(). */
    pointer-events: none;
    cursor: text;
  }
  .readonly-badge {
    position: absolute;
    right: 12px;
    bottom: 12px;
    background: var(--bg-2);
    border: 1px solid var(--bg-3);
    color: var(--fg-1);
    padding: 4px 8px;
    font-size: 11px;
    border-radius: 4px;
    pointer-events: none;
  }
  /* Find bar — overlaid top-right, stays in viewport regardless of scroll
     because it's a sibling of .editor (both abs-positioned inside
     .editor-host from EditorPane). */
  .find-bar {
    position: absolute;
    top: 8px;
    right: 16px;
    background: var(--bg-1);
    border: 1px solid var(--bg-3);
    border-radius: 6px;
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.3);
    padding: 6px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    z-index: 10;
    min-width: 340px;
  }
  .find-row {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .find-input {
    flex: 1;
    min-width: 0;
    background: var(--bg-0);
    color: var(--fg-0);
    border: 1px solid var(--bg-3);
    border-radius: 4px;
    padding: 4px 6px;
    font-family: var(--font-mono);
    font-size: 12px;
    outline: none;
  }
  .find-input:focus {
    border-color: var(--accent, #7aa2f7);
  }
  .find-input:disabled {
    color: var(--fg-2);
    background: var(--bg-1);
  }
  .find-count {
    font-size: 11px;
    color: var(--fg-2);
    font-family: var(--font-mono);
    min-width: 60px;
    text-align: right;
    padding: 0 4px;
    white-space: nowrap;
  }
  .find-btn {
    background: transparent;
    border: 1px solid transparent;
    color: var(--fg-1);
    cursor: pointer;
    font-size: 12px;
    padding: 3px 7px;
    border-radius: 3px;
    font-family: var(--font-mono);
    line-height: 1;
    min-width: 24px;
    height: 24px;
  }
  .find-btn.wide {
    min-width: 64px;
  }
  .find-btn:hover:not(:disabled) {
    background: var(--bg-2);
  }
  .find-btn.active {
    background: var(--bg-3);
    color: var(--fg-0);
  }
  .find-btn:disabled {
    color: var(--fg-2);
    cursor: default;
    opacity: 0.5;
  }
</style>
