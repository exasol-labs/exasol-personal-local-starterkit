'use client';
/**
 * The sidebar's own controls, both on its right edge: a drag handle that
 * resizes it, and the close button sitting on that line a little below its top. The width is one CSS variable
 * (--exakit-sidebar-width, read by global.css), kept in localStorage so every
 * page and the next visit open at the width the reader chose.
 */
import { SidebarCollapseTrigger } from 'fumadocs-ui/components/sidebar/base';
import { ChevronLeft } from 'lucide-react';
import { useCallback, useEffect, useRef } from 'react';

const KEY = 'exakit-docs-sidebar-width';
const DEFAULT = 268;
const MIN = 200;
const MAX = 520;

function apply(width: number) {
  const clamped = Math.round(Math.min(MAX, Math.max(MIN, width)));
  document.documentElement.style.setProperty('--exakit-sidebar-width', `${clamped}px`);
  return clamped;
}

function current() {
  const value = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--exakit-sidebar-width'), 10);
  return Number.isFinite(value) ? value : DEFAULT;
}

function save(width: number) {
  try {
    localStorage.setItem(KEY, String(width));
  } catch {
    // private window or blocked storage: the width still holds for this page
  }
}

export function SidebarTools() {
  const dragging = useRef(false);

  useEffect(() => {
    try {
      const saved = parseInt(localStorage.getItem(KEY) ?? '', 10);
      if (Number.isFinite(saved)) apply(saved);
    } catch {
      // no storage: the default width
    }
  }, []);

  const onPointerDown = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    dragging.current = true;
    event.currentTarget.setPointerCapture(event.pointerId);
    document.body.dataset.sidebarResizing = 'true';
    event.preventDefault();
  }, []);

  const onPointerMove = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging.current) return;
    const sidebar = document.getElementById('nd-sidebar');
    const left = sidebar ? sidebar.getBoundingClientRect().left : 0;
    apply(event.clientX - left);
  }, []);

  const onPointerUp = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging.current) return;
    dragging.current = false;
    event.currentTarget.releasePointerCapture(event.pointerId);
    delete document.body.dataset.sidebarResizing;
    save(current());
  }, []);

  const onKeyDown = useCallback((event: React.KeyboardEvent<HTMLDivElement>) => {
    const step = event.shiftKey ? 48 : 16;
    if (event.key === 'ArrowLeft') save(apply(current() - step));
    else if (event.key === 'ArrowRight') save(apply(current() + step));
    else if (event.key === 'Home') save(apply(DEFAULT));
    else return;
    event.preventDefault();
  }, []);

  return (
    <>
      <SidebarCollapseTrigger className="sidebar-close" title="Close sidebar">
        <ChevronLeft className="size-4" />
      </SidebarCollapseTrigger>
      <div
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize sidebar"
        title="Drag to resize. Double-click to reset."
        tabIndex={0}
        className="sidebar-resizer"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onDoubleClick={() => save(apply(DEFAULT))}
        onKeyDown={onKeyDown}
      />
    </>
  );
}
