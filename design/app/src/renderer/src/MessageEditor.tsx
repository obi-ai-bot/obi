import { useEffect, useImperativeHandle, useRef } from 'react';
import { LexicalComposer } from '@lexical/react/LexicalComposer';
import { useLexicalComposerContext } from '@lexical/react/LexicalComposerContext';
import { ContentEditable } from '@lexical/react/LexicalContentEditable';
import { LexicalErrorBoundary } from '@lexical/react/LexicalErrorBoundary';
import { HistoryPlugin } from '@lexical/react/LexicalHistoryPlugin';
import { PlainTextPlugin } from '@lexical/react/LexicalPlainTextPlugin';
import { registerLexicalTextEntity } from '@lexical/text';
import {
  $createParagraphNode, $getRoot, $getSelection, $isRangeSelection, $isTextNode, $setSelection, COMMAND_PRIORITY_HIGH,
  KEY_ARROW_DOWN_COMMAND, KEY_ARROW_UP_COMMAND, KEY_ENTER_COMMAND, KEY_ESCAPE_COMMAND, KEY_TAB_COMMAND, PASTE_COMMAND, type LexicalCommand,
} from 'lexical';
import { $createTokenNode, findToken, TokenNode } from './textTokens';
import { useScrollThumb } from './useScrollThumb';

// The message box's text, as Lexical (an open-source editor) keeps it: plain
// text you type and edit as usual, with what it recognises in it set apart as
// you go (see textTokens.ts). Enter sends; Shift+Enter starts a new line.
// An @ at the start of a word starts naming another Oby: what follows it goes
// to onMention for the box to offer the Obys it could be, and while it does,
// the arrows, Enter, Tab and Esc are the list's (onMentionKey).

export type MentionKey = 'up' | 'down' | 'pick' | 'close';
export type EditorHandle = {
  text(): string; clear(): void; focus(): void; blur(): void;
  mention(name: string): void;  // @name in place of the @ being typed (or at the cursor)
};
// the @ being typed, right before the cursor: what's after it so far
const AT = /(?:^|\s)@(\w*)$/;

export default function MessageEditor({ placeholder, label, autoFocus = false, onText, onEnter, onHeight, onPasteFiles, onMention, onMentionKey, handle }: {
  placeholder: string;
  label: string;
  autoFocus?: boolean;
  onText: (text: string) => void;       // after every change
  onEnter: () => void;                  // Enter (not Shift+Enter): send
  onHeight?: (height: number) => void;  // how tall the text has grown
  onPasteFiles?: (files: File[]) => void;  // pasted files (a screenshot, say): attached, not typed
  onMention?: (query: string | null) => void;  // an @ being typed: what follows it (null: none)
  onMentionKey?: (key: MentionKey) => boolean;  // true: the list took the key
  handle: React.Ref<EditorHandle>;
}) {
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLDivElement>();
  return (
    <LexicalComposer initialConfig={{ namespace: 'oby-message', nodes: [TokenNode], onError: (e) => { throw e; } }}>
      <div ref={list} className="composer-editor" onScroll={onScroll}>
        <PlainTextPlugin
          contentEditable={
            <ContentEditable
              className="composer-input"
              aria-label={label}
              aria-placeholder={placeholder}
              placeholder={<div className="composer-placeholder">{placeholder}</div>}
            />
          }
          ErrorBoundary={LexicalErrorBoundary}
        />
        <GlidingCaret />
      </div>
      {/* next to the text, not in it, so the text's fade doesn't fade it */}
      <div {...thumbProps} />
      <HistoryPlugin />
      <Behaviour autoFocus={autoFocus} onText={onText} onEnter={onEnter} onHeight={onHeight} onPasteFiles={onPasteFiles} onMention={onMention} onMentionKey={onMentionKey} handle={handle} />
    </LexicalComposer>
  );
}

// Inside the editor: spotting tokens, Enter to send, reporting changes and
// height, and the handle Composer reads, clears, focuses and blurs it by.
function Behaviour({ autoFocus, onText, onEnter, onHeight, onPasteFiles, onMention, onMentionKey, handle }: {
  autoFocus: boolean;
  onText: (text: string) => void;
  onEnter: () => void;
  onHeight?: (height: number) => void;
  onPasteFiles?: (files: File[]) => void;
  onMention?: (query: string | null) => void;
  onMentionKey?: (key: MentionKey) => boolean;
  handle: React.Ref<EditorHandle>;
}) {
  const [editor] = useLexicalComposerContext();
  // the latest callbacks, without re-registering on every render
  const cb = useRef({ onText, onEnter, onHeight, onPasteFiles, onMention, onMentionKey });
  cb.current = { onText, onEnter, onHeight, onPasteFiles, onMention, onMentionKey };

  useImperativeHandle(handle, () => ({
    text: () => editor.getEditorState().read(() => $getRoot().getTextContent()),
    clear: () => editor.update(() => { const root = $getRoot(); root.clear(); root.append($createParagraphNode()); }),
    focus: () => editor.focus(),
    // no cursor left behind to put back, so the editor doesn't take focus again
    blur: () => { editor.update(() => $setSelection(null)); editor.blur(); },
    mention: (name) => editor.update(() => {
      // no cursor (the + panel had the focus): at the end
      if (!$isRangeSelection($getSelection())) $getRoot().selectEnd();
      const s = $getSelection();
      if (!$isRangeSelection(s)) return;
      const n = s.anchor.getNode(), before = $isTextNode(n) && s.isCollapsed() ? n.getTextContent().slice(0, s.anchor.offset) : '';
      const at = AT.exec(before);
      if (at && $isTextNode(n)) {
        const from = before.length - at[1].length - 1;
        n.spliceText(from, before.length - from, `@${name} `, true);
      } else {
        // a space first if it would run into a word
        s.insertText(`${before && !/\s$/.test(before) ? ' ' : ''}@${name} `);
      }
    }),
  }), [editor]);

  useEffect(() => {
    const offs = [
      ...registerLexicalTextEntity(editor, findToken, TokenNode, (node) => $createTokenNode(node.getTextContent())),
      editor.registerCommand(KEY_ENTER_COMMAND, (e: KeyboardEvent | null) => {
        if (!e || e.isComposing) return false;
        if (!e.shiftKey && cb.current.onMentionKey?.('pick')) { e.preventDefault(); return true; }
        if (e.shiftKey) return false;
        e.preventDefault();
        cb.current.onEnter();
        return true;
      }, COMMAND_PRIORITY_HIGH),
      // a paste with files in it (an image copied or a screenshot): they're
      // attached instead, and nothing is typed
      editor.registerCommand(PASTE_COMMAND, (e: ClipboardEvent | InputEvent | KeyboardEvent) => {
        const files = 'clipboardData' in e && e.clipboardData ? [...e.clipboardData.files] : [];
        if (!files.length || !cb.current.onPasteFiles) return false;
        e.preventDefault();
        cb.current.onPasteFiles(files);
        return true;
      }, COMMAND_PRIORITY_HIGH),
      // while an @ is being typed, the list's keys (Esc kept from the page, which would close)
      ...([[KEY_ARROW_DOWN_COMMAND, 'down'], [KEY_ARROW_UP_COMMAND, 'up'], [KEY_TAB_COMMAND, 'pick'], [KEY_ESCAPE_COMMAND, 'close']] as const).map(([command, key]) =>
        editor.registerCommand(command as LexicalCommand<KeyboardEvent>, (e) => {
          if (e.isComposing || e.shiftKey || !cb.current.onMentionKey?.(key)) return false;
          e.preventDefault();
          e.stopPropagation();
          return true;
        }, COMMAND_PRIORITY_HIGH)),
      editor.registerUpdateListener(({ editorState }) => {
        cb.current.onText(editorState.read(() => $getRoot().getTextContent()));
        cb.current.onMention?.(editorState.read(() => {
          const s = $getSelection();
          if (!$isRangeSelection(s) || !s.isCollapsed()) return null;
          const n = s.anchor.getNode();
          return $isTextNode(n) ? AT.exec(n.getTextContent().slice(0, s.anchor.offset))?.[1] ?? null : null;
        }));
        const el = editor.getRootElement();
        if (el) cb.current.onHeight?.(el.scrollHeight);
      }),
    ];
    // Focus gone elsewhere in the window (a click outside, Tab): Lexical keeps
    // the cursor it had, and its next update would put it back and take the
    // focus with it, so it lets go of it. Not when the window itself goes to the
    // background: coming back, the cursor is where it was.
    const letGo = () => setTimeout(() => {
      const root = editor.getRootElement();
      if (root && document.hasFocus() && !root.contains(document.activeElement)) editor.update(() => $setSelection(null));
    });
    offs.push(editor.registerRootListener((root, prev) => {
      prev?.removeEventListener('blur', letGo);
      root?.addEventListener('blur', letGo);
    }));
    if (autoFocus) editor.focus();
    return () => offs.forEach((off) => off());
  }, [editor, autoFocus]);
  return null;
}

// The cursor, drawn by us in place of the system's (hidden in app.css), so it
// can glide as Word 2013's did: along a line (typing, arrowing) it slides to its
// new spot over 50ms (a touch, so the eye stays on the word), easing as it
// lands; to another line, or far off, it moves there at once. Still for half a
// second, it blinks; with text selected, or the box not focused, it hides.
// Reduce motion: no glide. It sits in the scrolling box with the text, placed
// where the text is rather than where it shows, so a scroll carries both
// together (no lag) and the faded edges fade both alike. It also keeps the box
// scrolled so its line is never under the faded edges.
const CARET = 20;  // the cursor's height, centred on its line
const GLIDE = 'transform 50ms cubic-bezier(0.22, 1, 0.36, 1)';
function GlidingCaret() {
  const [editor] = useLexicalComposerContext();
  const caret = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = caret.current!;
    let last: { x: number; y: number } | null = null, idle = 0, queued = 0, keep = false;
    // Where a line wraps, the spot between its last word and the next line's
    // first is both the end of one line and the start of the next. The page
    // doesn't say which the cursor is at, so we go by what put it there: the
    // start of the next line (as the system's cursor would), unless it was End
    // or Cmd+Right, or a click on the line above
    let wrapAt: 'start' | 'end' | number = 'start';
    const onKey = (e: KeyboardEvent) => {
      if (['Shift', 'Meta', 'Control', 'Alt'].includes(e.key)) return;
      wrapAt = e.key === 'End' || (e.metaKey && e.key === 'ArrowRight') || (e.ctrlKey && e.key === 'e') ? 'end' : 'start';
    };
    const onPointer = (e: PointerEvent) => { wrapAt = e.clientY; };
    // hidden, it stops blinking too: the blink runs apart from the page, with
    // the values it started with, and would carry on showing it otherwise
    const hide = () => { el.style.opacity = '0'; el.classList.remove('is-idle'); clearTimeout(idle); last = null; };
    const place = () => {
      queued = 0;
      // box: the scrolling box the text and the cursor are both in. Hidden with
      // the window in the background, as the system's cursor is
      const root = editor.getRootElement(), box = el.parentElement, sel = getSelection();
      if (!root || !box || !sel?.rangeCount || !sel.isCollapsed || document.activeElement !== root || !document.hasFocus() || !root.contains(sel.anchorNode)) return hide();
      const rect = caretRect(sel.getRangeAt(0), wrapAt);
      if (!rect) return hide();
      const b = box.getBoundingClientRect(), cs = getComputedStyle(root);
      // Spaces typed at a line's end hang past its edge; the cursor stops at the
      // edge, as a text field's does (following them, it made the box scroll sideways)
      const edge = root.getBoundingClientRect().right - parseFloat(cs.paddingRight);
      const x = Math.round(Math.min(rect.left, edge) - b.left + box.scrollLeft);
      const mid = rect.top + rect.height / 2 - b.top + box.scrollTop, y = Math.round(mid - CARET / 2);
      // The text changed or the cursor moved (not a scroll by hand): keep its line
      // clear of the room above and below the text, where the fade is. The
      // editor's own scroll only brings it inside the box, under the fade.
      if (keep) {
        keep = false;
        const top = parseFloat(cs.paddingTop), bottom = parseFloat(cs.paddingBottom);
        const line = parseFloat(cs.lineHeight), lineTop = mid - line / 2, lineBottom = mid + line / 2;
        if (lineBottom > box.scrollTop + box.clientHeight - bottom) box.scrollTop = lineBottom - box.clientHeight + bottom;
        else if (lineTop < box.scrollTop + top) box.scrollTop = lineTop - top;
      }
      const glide = last && Math.abs(y - last.y) < 2 && Math.abs(x - last.x) < 200 && !matchMedia('(prefers-reduced-motion: reduce)').matches;
      el.style.transition = glide ? GLIDE : 'none';
      el.style.transform = `translate(${x}px, ${y}px)`;
      el.style.opacity = '1';
      last = { x, y };
      // moving: solid; still for 500ms: blinking
      el.classList.remove('is-idle');
      clearTimeout(idle);
      idle = window.setTimeout(() => el.classList.add('is-idle'), 500);
    };
    // after the browser has laid out the change; moved (not focus alone): keep it in view
    const update = () => { if (!queued) queued = requestAnimationFrame(place); };
    const moved = () => { keep = true; update(); };
    // the text's box resized (the window, a panel beside it, stacking): the lines
    // may wrap differently, so the cursor's spot is found again
    const resized = new ResizeObserver(update);
    const offs = [
      editor.registerUpdateListener(moved),
      editor.registerRootListener((root, prev) => {
        for (const ev of ['focus', 'blur'] as const) { prev?.removeEventListener(ev, update); root?.addEventListener(ev, update); }
        prev?.removeEventListener('keydown', onKey, true); root?.addEventListener('keydown', onKey, true);
        prev?.removeEventListener('pointerdown', onPointer, true); root?.addEventListener('pointerdown', onPointer, true);
        if (prev) resized.unobserve(prev);
        if (root) resized.observe(root);
      }),
    ];
    document.addEventListener('selectionchange', moved);
    // the window going to the background and back (the box keeps its focus)
    addEventListener('blur', update);
    addEventListener('focus', update);
    return () => {
      resized.disconnect();
      offs.forEach((off) => off());
      document.removeEventListener('selectionchange', moved);
      removeEventListener('blur', update);
      removeEventListener('focus', update);
      clearTimeout(idle); cancelAnimationFrame(queued);
    };
  }, [editor]);
  return <div ref={caret} className="composer-caret" aria-hidden="true" />;
}
// Where a collapsed selection sits: its own rect, or (on an empty line, where
// it has none) the line's break or the element it's in. Where a line wraps it
// has two, the end of one line and the start of the next: wrapAt picks one
// (or, a click's height, the one on the line clicked).
function caretRect(range: Range, wrapAt: 'start' | 'end' | number): DOMRect | null {
  const rects = range.getClientRects();
  if (rects.length > 1) {
    if (wrapAt === 'end') return rects[0];
    if (wrapAt === 'start') return rects[rects.length - 1];
    return [...rects].find((r) => wrapAt < r.bottom) ?? rects[rects.length - 1];
  }
  if (rects.length) return rects[0];
  const n = range.startContainer;
  const el = n.nodeType === Node.ELEMENT_NODE ? ((n.childNodes[range.startOffset] as Element | undefined) ?? (n as Element)) : n.parentElement;
  return el && 'getBoundingClientRect' in el ? el.getBoundingClientRect() : null;
}
