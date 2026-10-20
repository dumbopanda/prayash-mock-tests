import { createClient } from './supabase.js'; // supabase-js 2.45.4, bundled so the app starts offline

// Publishable key: safe in the browser, access is enforced by row-level security.
export const sb = createClient(
  'https://rfenuwnboyktdprlmgct.supabase.co',
  'sb_publishable_XWZt491GsJ8Ze1NTLgmXqA__Xw4H5jW'
);

export async function currentUser() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data: p } = await sb.from('profiles').select('role,name').eq('id', session.user.id).single();
  return { id: session.user.id, email: session.user.email, ...p };
}

export async function logout() {
  await sb.auth.signOut();
  location.href = 'index.html';
}

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
