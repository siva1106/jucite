const saveBtn = document.getElementById('save-btn');
const statusDiv = document.getElementById('status');

let detectedDoi = "";
let currentTab = null;

const doiRegex = /\b(10\.\d{4,9}\/[-._;()/:A-Z0-9]+)\b/i;

// Scan page silently on open
chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  currentTab = tabs[0];
  if (!currentTab) return;

  // Check URL
  const urlMatch = currentTab.url.match(doiRegex);
  if (urlMatch) {
    detectedDoi = urlMatch[1].replace(/[.,;()]+$/, "");
    statusDiv.textContent = "DOI Detected";
    return;
  }

  // Scan Meta Tags
  chrome.scripting.executeScript({
    target: { tabId: currentTab.id },
    func: () => {
      const meta = document.querySelector('meta[name="citation_doi"], meta[name="dc.identifier"], meta[name="DOI"]');
      return meta ? meta.content : document.documentElement.outerHTML;
    }
  }, (results) => {
    if (results && results[0] && results[0].result) {
      const match = results[0].result.match(doiRegex);
      if (match) {
        detectedDoi = match[1].replace(/[.,;()]+$/, "");
        statusDiv.textContent = "DOI Detected";
        return;
      }
    }
    statusDiv.textContent = "Ready to save page/PDF";
  });
});

// ONE-CLICK SAVE BUTTON
saveBtn.addEventListener('click', () => {
  if (!currentTab) return;

  saveBtn.disabled = true;
  statusDiv.textContent = "Saving to Jucite...";

  const payload = {
    doi: detectedDoi,
    url: currentTab.url,
    title: currentTab.title || "Saved Document"
  };

  fetch('http://127.0.0.1:8080/api/save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
  .then(res => {
    if (res.ok) {
      statusDiv.innerHTML = "✅ Saved to Jucite!";
    } else {
      statusDiv.innerHTML = "❌ Failed to save.";
      saveBtn.disabled = false;
    }
  })
  .catch(err => {
    statusDiv.innerHTML = "❌ Server offline.";
    saveBtn.disabled = false;
  });
});