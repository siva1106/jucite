# 📚 Jucite Reference Manager — Official User Manual

Welcome to **Jucite**, a lightning-fast, local-first academic reference manager designed for researchers, students, and collaborative teams. 

---

## 1. Getting Started & Installation

### A. Launch Jucite Desktop
1. Download the latest release for your system (`Jucite-Linux-x86_64.AppImage` for Linux or `Jucite-Windows-x64.zip` for Windows).
2. **Linux Users:** Right-click the `.AppImage` file -> *Properties* -> *Permissions* -> Check **"Allow executing file as program"**, then double-click to launch.
3. **Important:** Keep Jucite Desktop running in the background whenever you want to save papers from Chrome or cite in Google Docs™.

### B. Install the Jucite Chrome Connector
1. Open Jucite and go to **Edit > Preferences > Cite**.
2. Click **Install Connector** next to Google Chrome / Brave.
3. Add the extension to your browser and pin the **J** icon to your toolbar.

### C. Install the Google Docs™ Plugin
1. Open any Google Doc (`docs.new`).
2. Go to **Extensions > Add-ons > Get add-ons**.
3. Search for **Jucite** and click **Install**.

---

## 2. Adding Papers to Your Library

Jucite gives you three effortless ways to build your library:

1. **1-Click Web Saver (Chrome Connector):** 
   Browse to *any* journal article (Nature, IEEE, Science, PLOS, PubMed) or open a raw PDF tab in Chrome. Click the **Jucite (J)** icon in your toolbar and hit **Save to Jucite**. Jucite automatically extracts the metadata and downloads open-access PDFs!
2. **Add by Identifier (Magic Wand ✨):** 
   Click the purple **Magic Wand** icon on the Jucite toolbar, paste any DOI (e.g., `10.1371/journal.pone.0115069`), and click **Add to Library**.
3. **Smart File Import (`File > Import...`):** 
   - **Import a PDF:** Select a PDF from your computer; Jucite reads the header metadata, identifies the paper, and imports it cleanly.
   - **Batch Import DOIs:** Select a `.txt` file containing a list of DOIs to automatically fetch and download all of them at once.

---

## 3. Organizing & Managing Your Research

* **Reading PDFs:** Papers with downloaded PDFs show a red **PDF icon**. **Double-click** any paper row (or click the *Full Text PDF* box in the right-hand **Info** tab) to open the paper in your system's PDF reader.
* **Collections & Group Libraries:** Click the yellow **Folder+** icon to create personal folders, or the blue **Users+** icon to create shared Group Libraries.
* **Move or Delete Papers (`⋮` Menu):** Click the **3-dot menu** on the far right of any paper row to move it into a specific Collection/Group, or send it to the **Trash**.
* **Notes & Tags:** Select any paper and switch to the **Notes** or **Tags** tabs on the right pane to save personal research notes or organize with custom tags.
* **Smart Views:** Use **Recently Read**, **Duplicate Items**, and **My Publications** (configure your last name under *Edit > Preferences > General*) on the left sidebar to quickly filter your work.
* **Trash Management:** Click **Trash** in the left sidebar and click the `⋮` menu on any deleted paper to either **Restore to Library** or **Delete Permanently** (which permanently removes the database entry and the local PDF).

---

## 4. Google Drive™ Cloud Sync (Zero-Cost Backup)

Jucite backs up your library directly to your personal Google Drive account—giving you unlimited storage under your own control.

1. Go to **Edit > Preferences > Sync**.
2. Click **Link Google Drive Account**, sign in with Google, and click **Allow**. *(Your account stays linked automatically in the background).*
3. Click the green **Sync (↻)** icon on the top toolbar anytime to sync.
   - **Clean Organization:** Jucite creates a `Jucite Library` folder in your Google Drive, neatly separated into `My Library` and `Group Libraries`.
   - **Smart File Handling:** Jucite uploads the PDF if available, or creates a clean `_Metadata.txt` summary card if the paper is paywalled. Deleted papers are automatically cleaned up from Google Drive on your next sync.

---

## 5. Collaborating with Teammates (Group Libraries)

Share papers and PDFs with your research team completely inside Jucite—no manual Google Drive folder sharing required!

### To Share a Group (Team Lead):
1. Create a **Group Library** (e.g., `jutarget`) and move/add papers into it.
2. Click the **`👤+` (Share)** icon right next to the group name in the left sidebar.
3. Enter your teammate's Gmail address, choose **Can Edit** or **Can View**, and click **Send Invite**.

### To Receive Shared Papers (Teammate):
1. Link your own Google account in **Edit > Preferences > Sync**.
2. Click the green **Sync (↻)** icon on the top toolbar.
3. Jucite automatically discovers any groups shared with you, adds them to your left sidebar, and downloads the papers and PDFs directly to your computer!

---

## 6. Citing & Writing in Google Docs™

1. Open your Google Doc and click **Extensions > 📚 Jucite > Zotero-Style Plugin**.
2. **Choose a Citation Style:** Click **⚙️ Document Preferences** and search over **10,000+ official CSL styles** (e.g., *APA 7th*, *Vancouver Superscript*, *IEEE*, *Nature*, *The Lancet*).
3. **Insert Citations:** Place your cursor in your text, click **📄 Add/Edit Citation**, search by author, title, or year, and click the paper.
4. **Update & Auto-Number Bibliography:** Click **🔄 Update Bibliography** (or **🔄 Refresh**) anytime. Jucite scans your entire document, dynamically updates all in-text numbers (e.g., `[1]`, `[2]` or `¹`, `²`), removes references you deleted from your text, and generates a clean **References** section at the bottom.
5. **Finalize Your Paper:** Before submitting your manuscript to a journal, click **🔗 Unlink Citations** to convert all tracked citations into permanent plain text.
