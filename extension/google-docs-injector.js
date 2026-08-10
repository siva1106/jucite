// google-docs-injector.js
console.log("📚 Jucite Connector detected Google Docs!");

// Create a floating Jucite button on the Google Doc page
const juciteBtn = document.createElement("button");
juciteBtn.innerHTML = "📚 Cite with Jucite";
juciteBtn.style.cssText = "position:fixed; top:15px; right:200px; z-index:9999; background:#4f46e5; color:white; border:none; padding:8px 16px; border-radius:4px; font-weight:bold; cursor:pointer; font-family:sans-serif; font-size:12px; box-shadow:0 2px 5px rgba(0,0,0,0.2);";

juciteBtn.onclick = () => {
    alert("Jucite Connector is active! To insert citations securely, use the Extensions > Jucite menu.");
    // In a full production build, this button would trigger a bridge to the Google Docs API!
};

document.body.appendChild(juciteBtn);