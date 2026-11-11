import { loader } from 'fumadocs-core/source';
import { docsContentRoute, docsRoute, withBasePath } from './shared';
import { defineDocs } from 'fumadocs-mdx/macro';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';

const docs = defineDocs({
  dir: 'content/docs',
  docs: {
    schema: pageSchema,
    postprocess: {
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    schema: metaSchema,
  },
});

// See https://fumadocs.dev/docs/headless/source-api for more info
export const source = loader({
  baseUrl: docsRoute,
  source: docs.toFumadocsSource(),
  plugins: [],
});

export function getPageMarkdownUrl(page: (typeof source)['$inferPage']) {
  const segments = [...page.slugs, 'content.md'];

  return {
    segments,
    url: withBasePath('/' + [page.locale, ...docsContentRoute.split('/'), ...segments].filter(Boolean).join('/')),
  };
}

export async function getLLMText(page: (typeof source)['$inferPage']) {
  // Typed structurally: the generic inference that adds getText/full to
  // PageData is fragile under workspace hoisting, and the shape is stable.
  const processed = await (page.data as unknown as { getText(mode: 'processed' | 'raw'): Promise<string> }).getText(
    'processed',
  );

  return `# ${page.data.title} (${page.url})

${processed}`;
}
