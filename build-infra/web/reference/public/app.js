// Front-end: call the back-end's REST endpoint and show the result. Extend for your UI.
fetch('/api/health')
  .then((r) => r.json())
  .then((d) => {
    document.getElementById('status').textContent = d.ok ? `OK (sum = ${d.sum})` : 'Error';
  })
  .catch(() => {
    document.getElementById('status').textContent = 'Offline';
  });
