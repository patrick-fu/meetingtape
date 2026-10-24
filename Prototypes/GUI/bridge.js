window.reportState = function (state) {
  window.__prototypeState = state;
  window.parent.postMessage({ type: 'meetingtape:state', state }, location.origin);
};
window.addEventListener('keydown', event => {
  if (event.target.closest('input, textarea, select, [contenteditable="true"]')) return;
  if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
  event.preventDefault();
  window.parent.postMessage({ type: 'meetingtape:cycle', direction: event.key === 'ArrowRight' ? 1 : -1 }, location.origin);
});
window.addEventListener('message', event => {
  if (event.origin === location.origin && event.data.type === 'meetingtape:request-state' && window.__prototypeState) {
    window.reportState(window.__prototypeState);
  }
});
