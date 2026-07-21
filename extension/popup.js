const saveBtn = document.getElementById('save-btn');
const statusDiv = document.getElementById('status');
let detectedDoi = null;

// Regular expression to find a standard DOI format on the webpage
const doiRegex = /\b(10\.\d{4,9}\/[-._;()/:A-Z0-9]+)\b/i;

/**
 * Scans the active browser tab to look for a DOI.
 */
function scanPageForDoi() {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const tab = tabs[0];
    if (!tab) return;

    // 1. Try to find the DOI directly in the tab's URL
    const urlMatch = tab.url.match(doiRegex);
    if (urlMatch) {
      setDoiFound(urlMatch[1]);
      return;
    }

    // 2. If not in the URL, inject a script to scan the webpage's raw HTML
    chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => document.documentElement.outerHTML
    }, (results) => {
      if (!results || !results[0]) {
        statusDiv.textContent = "Could not scan page content.";
        return;
      }

      const htmlContent = results[0].result;
      const bodyMatch = htmlContent.match(doiRegex);

      if (bodyMatch) {
        setDoiFound(bodyMatch[1]);
      } else {
        statusDiv.textContent = "No DOI detected on this page.";
      }
    });
  });
}

function setDoiFound(doi) {
  // Clean up any trailing punctuation caught in the regex match
  detectedDoi = doi.replace(/[.,;()]+$/, "");
  statusDiv.innerHTML = `Found DOI:<br><strong>${detectedDoi}</strong>`;
  saveBtn.disabled = false;
}

// Handle clicking the "Save to Jucite" button
saveBtn.addEventListener('click', () => {
  if (!detectedDoi) return;

  saveBtn.disabled = true;
  statusDiv.textContent = "Saving to Jucite...";

  // Make the API call to our local Julia server!
  fetch('http://localhost:8080/api/save', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ doi: detectedDoi })
  })
  .then(response => {
    if (response.ok) {
      statusDiv.innerHTML = "✅ Paper saved successfully!";
    } else {
      statusDiv.innerHTML = "❌ Failed to save (server error).";
      saveBtn.disabled = false;
    }
  })
  .catch(error => {
    statusDiv.innerHTML = "❌ Error: Is Jucite server running?";
    saveBtn.disabled = false;
  });
});

// Start scanning as soon as the popup opens
scanPageForDoi();