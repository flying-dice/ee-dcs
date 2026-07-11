// HUD monospace (readouts, labels) + angular military techno sans (body, controls).
import '@fontsource/share-tech-mono/400.css';
import '@fontsource/chakra-petch/400.css';
import '@fontsource/chakra-petch/500.css';
import '@fontsource/chakra-petch/600.css';
import './app.css';
import App from './App.svelte';

const app = new App({
  target: document.getElementById('app')!,
});

export default app;
