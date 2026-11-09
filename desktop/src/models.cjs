const prompts = require('./prompts.json');

function endpoint(settings) {
  let url;
  try { url = new URL(settings.provider === 'deepseek' ? 'https://api.deepseek.com' : settings.url.trim()); }
  catch { throw new Error('请填写有效的模型接口地址。'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.hash) throw new Error('模型地址仅支持 HTTP 或 HTTPS，不允许内嵌凭据。');
  const route = url.pathname.replace(/\/+$/, '');
  if (!route.endsWith('/chat/completions')) url.pathname = route + '/chat/completions';
  return url;
}
async function completion(settings, key, messages, { signal, maxTokens = 4096, fetchImpl = fetch, local = false } = {}) {
  const url = endpoint(settings);
  if (!settings.model?.trim() || !key?.trim() || /[\r\n]/.test(key)) throw new Error('请在设置中填写模型名称和 API key。');
  const body = { model: settings.model.trim(), messages, stream: false, max_tokens: maxTokens };
  if (!local && (settings.provider === 'deepseek' || (url.hostname === 'i-nhi.zhejianglab.org' && settings.model.toLowerCase().startsWith('deepseek-v4')))) body.thinking = { type: 'disabled' };
  const timeout = AbortSignal.timeout(local ? 180000 : 180000);
  let response;
  try {
    response = await fetchImpl(url, { method: 'POST', redirect: 'error', signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` }, body: JSON.stringify(body) });
  } catch (error) {
    if (signal?.aborted) throw new Error('已取消。');
    if (timeout.aborted) throw new Error('模型请求超时，请缩短选文或重试。');
    throw new Error('无法连接模型服务，请检查接口地址、网络与 TLS 配置。');
  }
  if (!response.ok) {
    const messages = { 401: 'API 认证失败，请检查 API key。', 403: '没有此模型的访问权限。', 402: 'API 账户余额不足。',
      404: '找不到接口或模型，请检查配置。', 429: '请求频繁或配额不足，请稍后重试。' };
    throw new Error(messages[response.status] || `模型请求失败（HTTP ${response.status}）。`);
  }
  const raw = await response.text();
  if (raw.length > 2_000_000) throw new Error('模型响应过大。');
  let result;
  try { result = JSON.parse(raw); } catch { throw new Error('模型接口未返回合法 JSON 响应。'); }
  const choice = result.choices?.[0];
  if (!choice || typeof choice.message?.content !== 'string' || !choice.message.content.trim()) throw new Error('模型没有返回有效内容。');
  if (['content_filter', 'tool_calls'].includes(choice.finish_reason)) throw new Error('模型未返回完整内容，请重试。');
  return { text: choice.message.content.trim(), truncated: choice.finish_reason === 'length' };
}
function decodeJSON(reply) {
  if (reply.truncated) throw new Error('模型输出被截断，请缩短选文后重试。');
  try { return JSON.parse(reply.text.replace(/^```(?:json)?\s*\n?/, '').replace(/\n?```$/, '')); }
  catch { throw new Error('模型结果格式不完整，请重试。'); }
}
function decodeAnalysis(reply) {
  const result = decodeJSON(reply);
  if (!['translation', 'mainStructure', 'diagram'].every(key => typeof result[key] === 'string' && result[key].trim())
    || !/\n/.test(result.diagram) || !/➔|→|->|├|└|│/.test(result.diagram)
    || !['modifiers', 'grammarPoints'].every(key => Array.isArray(result[key]) && result[key].every(value => typeof value === 'string')))
    throw new Error('分析缺少主干、译文或完整结构图，请重试。');
  return result;
}
function decodeDefinition(reply) {
  const result = decodeJSON(reply);
  if (!['head', 'reading', 'meaning'].every(key => typeof result[key] === 'string' && result[key].trim())) throw new Error('模型释义不完整，请重试。');
  return { head: result.head.trim(), reading: result.reading.trim(), chinese: [result.meaning, result.note].filter(Boolean).join('\n'), etymology: typeof result.etymology === 'string' ? result.etymology : '' };
}
module.exports = { endpoint, completion, decodeJSON, decodeAnalysis, decodeDefinition, prompts };
