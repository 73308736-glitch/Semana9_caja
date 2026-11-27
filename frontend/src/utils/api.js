const API_BASE = import.meta.env.VITE_API_URL || '/api';
export async function apiRequest(path, options = {}) {
  const token = localStorage.getItem('mb_token');
  const response = await fetch(API_BASE + path, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...options.headers }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || 'Ocurrió un error.');
  return data;
}
export const formatMoney = value => 'S/ ' + Number(value || 0).toFixed(2);