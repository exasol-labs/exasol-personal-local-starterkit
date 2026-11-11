'use client';
import {
  SearchDialog,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
  type SharedProps,
} from 'fumadocs-ui/components/dialog/search';
import { useDocsSearch } from 'fumadocs-core/search/client';
import { staticClient } from 'fumadocs-core/search/client/orama-static';
import { useI18n } from 'fumadocs-ui/contexts/i18n';
import { useEffect, useMemo } from 'react';
import { withBasePath } from '@/lib/shared';

/*
 * Search runs in the browser on the index shipped with the site: no service,
 * no network. Tuned the way the hosted engines do it by default:
 *
 * - search as you type: every word also matches the words that start with it
 *   (the engine's prefix matching, on by default; a full-word match ranks higher);
 * - typo tolerance that grows with the word, as Elasticsearch's AUTO fuzziness
 *   and Algolia's typo rules do: none for words up to 3 letters (a typo there
 *   is another word), one edit for 4-7 letters, two from 8 letters;
 * - a query of several words finds pages with any of them and ranks the pages
 *   with all of them first (BM25), so a half-remembered phrase still lands;
 * - hits are grouped under their page and link to the heading they sit under.
 */
function tolerance(query: string): number {
  const longest = query.split(/[^\p{L}\p{N}_]+/u).reduce((n, word) => Math.max(n, word.length), 0);
  if (longest >= 8) return 2;
  if (longest >= 4) return 1;
  return 0;
}

export default function DefaultSearchDialog(props: SharedProps) {
  const { locale } = useI18n(); // (optional) for i18n
  const client = useMemo(() => {
    // One index, loaded once (the client caches it by URL); the tolerance is chosen per query.
    const from = withBasePath('/api/search');
    const byTolerance = [0, 1, 2].map((t) => staticClient({ locale, from, search: { tolerance: t } }));
    return {
      deps: [locale],
      search: (query: string) => byTolerance[tolerance(query)].search(query),
    };
  }, [locale]);
  const { search, setSearch, query } = useDocsSearch({ client });

  // nb.docs("descriptor") opens the site at ?q=descriptor: the dialog opens on that search.
  const { onOpenChange } = props;
  useEffect(() => {
    const term = new URLSearchParams(window.location.search).get('q');
    if (!term) return;
    setSearch(term);
    onOpenChange(true);
    // once, on arrival
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <SearchDialog search={search} onSearchChange={setSearch} isLoading={query.isLoading} {...props}>
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList items={query.data !== 'empty' ? query.data : null} />
      </SearchDialogContent>
    </SearchDialog>
  );
}
