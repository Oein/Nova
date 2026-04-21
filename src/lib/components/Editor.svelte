<script lang="ts">
  import { onDestroy, onMount, tick } from "svelte";
  import type { Buffer, BufferChange } from "$lib/editor/buffer/Buffer";
  import type { OpenTab } from "$lib/types";
  import { RopeBuffer } from "$lib/editor/buffer/RopeBuffer";
  import { applyCommand, keymap } from "$lib/editor/commands";
  import { primary, ordered, isEmpty, withPrimary, type CursorState } from "$lib/editor/selection";
  import type { Pos } from "$lib/editor/buffer/Buffer";
  import { metrics } from "$lib/editor/measure";
  import { graphemes } from "$lib/editor/grapheme";
  import { computeWrapStarts, subRowAt, bufferLineAtVisualRow } from "$lib/editor/wrap";
  import { saveActive } from "$lib/tabManager";
  import { updateCursor, updateScroll, getTabRuntime } from "$lib/sessionManager";
  import { editorStatus } from "$lib/stores/editorStatus";

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
  onDestroy(() => {
    if (unsub) unsub();
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

  function publishStatus(c: CursorState) {
    const head = primary(c).head;
    editorStatus.set({
      line: head.line,
      col: head.col,
      selectionChars: selectionCharLength(c),
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
    scrollCaretIntoView();
  }

  function onKeyDown(e: KeyboardEvent) {
    if (composing || e.isComposing || e.key === "Process" || e.keyCode === 229) return;
    if ((e.metaKey || e.ctrlKey) && (e.key === "s" || e.key === "S")) {
      e.preventDefault();
      saveActive();
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
    cursor = { selections: [{ anchor: pos, head: pos }], primary: 0 };
    publishStatus(cursor);
    updateCursor(tab.id, pos.line, pos.col);
    focusInput();
    const move = (ev: MouseEvent) => {
      const p2 = hitTest(ev);
      if (!p2) return;
      cursor = { ...cursor, selections: [{ anchor: cursor.selections[0].anchor, head: p2 }] };
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
    const rect = rowsHost.getBoundingClientRect();
    const y = e.clientY - rect.top + viewport.scrollTop;
    const x = e.clientX - rect.left + viewport.scrollLeft - contentLeft;
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
</script>

<svelte:window on:resize={onResize} />

<!-- svelte-ignore a11y-no-static-element-interactions -->
<div
  class="editor"
  bind:this={viewport}
  on:scroll={onScroll}
  on:mousedown={onMouseDown}
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
      {#each visibleLines as r (r.yRow)}
        <div class="row" style="top: {r.yRow * rowHeight}px; height: {rowHeight}px">
          {#if r.text}
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
      {#if composing}
        <div
          class="preedit"
          style="top: {caret.yRow * rowHeight}px; height: {rowHeight}px; left: {caret.xPx}px"
        >
          {compositionText}
        </div>
      {/if}
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
        on:paste={onPaste}
        on:copy={onCopy}
        on:cut={onCut}
        on:blur={onInputBlur}
        style="top: {caret.yRow * rowHeight}px; left: {caret.xPx}px; height: {rowHeight}px"
      ></textarea>
    </div>
  </div>

  {#if !buffer.editable}
    <div class="readonly-badge">Read-only (large file)</div>
  {/if}
</div>

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
  .caret {
    position: absolute;
    width: 1.5px;
    background: var(--fg-0);
    animation: blink 1s steps(2) infinite;
    pointer-events: none;
  }
  @keyframes blink { 50% { opacity: 0; } }
  .preedit {
    position: absolute;
    color: var(--accent);
    text-decoration: underline;
    pointer-events: none;
    line-height: var(--editor-row-height, 20px);
    white-space: pre;
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
</style>
