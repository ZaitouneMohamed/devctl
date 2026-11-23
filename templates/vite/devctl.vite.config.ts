// Added by devctl. Not part of the project: devctl adds it to .git/info/exclude.
// Runs the project's own vite.config with devctl's settings for live reload over HTTPS:
// Vite listens on 127.0.0.1, Caddy serves it at https://<site>.test:<port> with the
// site's certificate, so the page and its assets share one trusted origin.
import { defineConfig, mergeConfig, type UserConfig } from 'vite';
import base from './vite.config';

const env = (name: string): string => {
    const value = process.env[name];
    if (!value) throw new Error(`${name} is not set: start Vite with "devctl site dev <name>"`);
    return value;
};

export default defineConfig(async (configEnv) => {
    const resolved: UserConfig = typeof base === 'function' ? await base(configEnv) : await base;
    const host = env('DEVCTL_SITE_HOST');
    const publicPort = Number(env('DEVCTL_VITE_PUBLIC_PORT'));
    return mergeConfig(resolved, {
        server: {
            host: '127.0.0.1',
            port: Number(env('DEVCTL_VITE_PORT')),
            strictPort: true,
            origin: `https://${host}:${publicPort}`,
            cors: { origin: env('DEVCTL_APP_URL') },
            hmr: { host, clientPort: publicPort, protocol: 'wss' },
        },
    });
});
