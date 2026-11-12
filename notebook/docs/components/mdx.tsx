import defaultMdxComponents from 'fumadocs-ui/mdx';
import { Tab, Tabs } from 'fumadocs-ui/components/tabs';
import { Step, Steps } from 'fumadocs-ui/components/steps';
import { Accordion, Accordions } from 'fumadocs-ui/components/accordion';
import type { MDXComponents } from 'mdx/types';
import { Flow, StageMap, StageNav } from './workflow';

export function getMDXComponents(components?: MDXComponents) {
  return {
    ...defaultMdxComponents,
    // Available in every page without imports — the content uses them freely.
    Tab,
    Tabs,
    Step,
    Steps,
    Accordion,
    Accordions,
    Flow,
    StageMap,
    StageNav,
    ...components,
  } satisfies MDXComponents;
}

export const useMDXComponents = getMDXComponents;

declare global {
  type MDXProvidedComponents = ReturnType<typeof getMDXComponents>;
}
