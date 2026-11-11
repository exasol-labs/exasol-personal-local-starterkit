export const appName = 'Starter Kit';
// Docs pages live at the root of the app; the /docs prefix comes from
// next.config's basePath, which the kit's docs server (exakit_nb/docs.py) serves them under.
export const docsRoute = '/';
export const docsContentRoute = '/llms.mdx/docs';
// basePath is not applied to plain fetch()/meta URLs, only to next/link.
export const withBasePath = (url: string) => `/docs${url === '/' ? '' : url}`;
