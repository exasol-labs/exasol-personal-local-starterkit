'use client';
/**
 * The words beside the logo: "Starter Kit - <section>", where the section is
 * the one being read - the persona picked at the top of the sidebar (a root
 * folder of content/docs, named by its meta.json), or the site itself on the
 * landing page. Nothing here names a persona: a new section shows its own title.
 */
import { useTreeContext } from 'fumadocs-ui/contexts/tree';

export function BrandLabel({ app }: { app: string }) {
  const { root } = useTreeContext();
  const section = typeof root.name === 'string' ? root.name.trim() : '';
  return <>{section ? `${app} - ${section}` : app}</>;
}
