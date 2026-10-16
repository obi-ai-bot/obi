import { defineConfig } from 'electron-vite';
import renderer from './vite.config';

export default defineConfig({
  main: {},
  preload: {},
  renderer,
});
