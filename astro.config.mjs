import { defineConfig } from 'astro/config';
export default defineConfig({
  site: 'https://ourport.us',
  output: 'static',
  trailingSlash: 'always',
  devToolbar: { enabled: false },
});
