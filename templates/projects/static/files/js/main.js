// Runs after the page has loaded (script tag uses "defer").
document.getElementById("clock").textContent = `Loaded at ${new Date().toLocaleTimeString()}`;
