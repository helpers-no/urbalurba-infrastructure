import { themes as prismThemes } from 'prism-react-renderer';
import type { Config } from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import * as fs from 'fs';
import * as path from 'path';

// THE version. One number for the whole product - the launcher, the container
// image and this site all report it, so "what am I running?" has one answer.
//
// Read from version.txt at the repository root, which is the same file the
// image build copies in and the same file `./uis pull` compares against. If it
// is ever read from somewhere else, the two can disagree, which is the entire
// problem this is meant to close.
//
// Deliberately NOT hardcoded here: a version duplicated in a config file is a
// version that will be stale within a week.
function readVersion(): string {
  try {
    return fs.readFileSync(path.join(__dirname, '..', 'version.txt'), 'utf8').trim();
  } catch {
    // Never fail the build over a badge. An empty string means the navbar item
    // is dropped rather than showing a wrong or placeholder number - a version
    // nobody can trust is worse than none.
    return '';
  }
}
const UIS_VERSION = readVersion();

// GitHub organization and repository from environment or defaults
const GITHUB_ORG = process.env.GITHUB_ORG || 'helpers-no';
const GITHUB_REPO = process.env.GITHUB_REPO || 'urbalurba-infrastructure';

const config: Config = {
  title: 'Urbalurba Infrastructure Stack',
  tagline: 'Complete datacenter on your laptop',
  favicon: 'img/favicon.ico',

  // Production URL
  url: 'https://uis.sovereignsky.no',
  baseUrl: '/',

  // GitHub Pages deployment config
  organizationName: GITHUB_ORG,
  projectName: GITHUB_REPO,
  trailingSlash: false,

  onBrokenLinks: 'warn',
  onBrokenAnchors: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  markdown: {
    mermaid: true,
    format: 'detect',
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: `https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/tree/main/website/`,
        },
        blog: {
          showReadingTime: true,
          editUrl: `https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/tree/main/website/`,
        },
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themes: ['@docusaurus/theme-mermaid'],

  plugins: [
    'docusaurus-plugin-image-zoom',
    [
      '@easyops-cn/docusaurus-search-local',
      {
        hashed: true,
        language: ['en'],
        highlightSearchTermsOnTargetPage: true,
        explicitSearchResultPath: true,
        docsRouteBasePath: '/docs',
      },
    ],
  ],

  themeConfig: {
    image: 'img/social-card.jpg',
    navbar: {
      title: 'Urbalurba Infrastructure Stack',
      logo: {
        alt: 'Urbalurba Infrastructure Stack Logo',
        src: 'img/brand/uis-logo-green.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: 'Docs',
        },
        { to: '/services', label: 'Services', position: 'left' },
        { to: '/blog', label: 'Blog', position: 'left' },
        {
          href: `https://github.com/${GITHUB_ORG}/${GITHUB_REPO}`,
          label: 'GitHub',
          position: 'right',
        },
        // The version, shown the way devcontainer-toolbox shows its own: a
        // badge in the navbar, present on every page. Omitted entirely if
        // version.txt could not be read.
        ...(UIS_VERSION
          ? [{
              type: 'html' as const,
              position: 'right' as const,
              value: `<span class="badge badge--secondary">v${UIS_VERSION}</span>`,
            }]
          : []),
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Documentation',
          items: [
            {
              label: 'Getting Started',
              to: '/docs/getting-started/overview',
            },
            {
              label: 'Services',
              to: '/docs/services/ai',
            },
            {
              label: 'Platforms',
              to: '/docs/platforms',
            },
          ],
        },
        {
          title: 'Resources',
          items: [
            {
              label: 'GitHub',
              href: `https://github.com/${GITHUB_ORG}/${GITHUB_REPO}`,
            },
            {
              label: 'SovereignSky',
              href: 'https://sovereignsky.no',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} SovereignSky. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'yaml', 'json', 'typescript', 'python'],
    },
    zoom: {
      selector: '.markdown img',
      background: {
        light: 'rgb(255, 255, 255)',
        dark: 'rgb(50, 50, 50)',
      },
    },
    colorMode: {
      defaultMode: 'light',
      disableSwitch: false,
      respectPrefersColorScheme: true,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
