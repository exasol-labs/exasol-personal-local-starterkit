import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/notebook';
import { baseOptions } from '@/lib/layout.shared';
import { SidebarTools } from '@/components/sidebar-tools';

// The notebook layout: a full-width top navbar (brand, search, links, GitHub,
// theme pill) with the page tree in a clean sidebar below it.
export default function Layout({ children }: { children: React.ReactNode }) {
  const base = baseOptions();
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...base}
      nav={{ ...base.nav, mode: 'top' }}
      tabMode="sidebar"
      sidebar={{ banner: <SidebarTools key="sidebar-tools" /> }}
    >
      {children}
    </DocsLayout>
  );
}
