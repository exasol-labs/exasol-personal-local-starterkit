import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  // Served by the kit's own Python (exakit.nb docs()) under /docs: a static export, no Node at run time.
  basePath: '/docs',
  reactStrictMode: true,
  images: { unoptimized: true },
};

export default withMDX(config);
