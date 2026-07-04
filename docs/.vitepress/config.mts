import { defineConfig } from 'vitepress'
import llmstxt from 'vitepress-plugin-llms'

export default defineConfig({
  vite: {
    plugins: [llmstxt()],
  },
  title: 'ours-mufl-core',
  description: 'The shared agent-to-agent protocol core for ours.network — agent-centered documentation.',
  base: '/ours-mufl-core/',          // flip to '/' if/when docs.ours.network lands (SPEC Q2)
  ignoreDeadLinks: false,            // dead internal links fail the build (SPEC C4/NFR4)
  markdown: {
    languageAlias: { mufl: 'txt' }   // render ```mufl fences verbatim (SPEC C5)
  },
  themeConfig: {
    search: { provider: 'local' },
    nav: [
      { text: 'How it works', link: '/how-it-works/overview' },
      { text: 'Build on it', link: '/guide/' },
      { text: 'Reference', link: '/reference/modules' }
    ],
    sidebar: {
      '/how-it-works/': [{ text: 'How it works', items: [
        { text: 'Overview', link: '/how-it-works/overview' },
        { text: 'Identity: roots & roles', link: '/how-it-works/identity' },
        { text: 'Invites & contacts', link: '/how-it-works/invites-and-contacts' },
        { text: 'Messaging', link: '/how-it-works/messaging' },
        { text: 'Capabilities & control', link: '/how-it-works/capabilities-and-control' },
        { text: 'Cluster', link: '/how-it-works/cluster' },
        { text: 'Monitoring & config', link: '/how-it-works/monitoring-and-config' },
        { text: 'Versioning', link: '/how-it-works/versioning' }
      ]}],
      '/guide/': [{ text: 'Build your own app', items: [
        { text: 'Start here', link: '/guide/' },
        { text: '01 · Vendor the core', link: '/guide/01-vendor-the-core' },
        { text: '02 · Configure & compile', link: '/guide/02-configure-and-compile' },
        { text: '03 · Wire the host', link: '/guide/03-wire-the-host' },
        { text: '04 · Connect & message', link: '/guide/04-connect-and-message' },
        { text: '05 · Test your app', link: '/guide/05-test-your-app' }
      ]}],
      '/reference/': [{ text: 'Reference', items: [
        { text: 'Modules', link: '/reference/modules' },
        { text: 'Reference implementations', link: '/reference/implementations' },
        { text: 'Glossary', link: '/reference/glossary' },
        { text: 'Contributing', link: '/reference/contributing' }
      ]}]
    },
    socialLinks: [{ icon: 'github', link: 'https://github.com/adapt-toolkit/ours-mufl-core' }]
  }
})
