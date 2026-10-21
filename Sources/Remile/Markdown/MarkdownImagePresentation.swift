import Foundation

/// Shared reading and Search image states; no direct network access from page content.
enum MarkdownImagePresentation {
    static let script = """
    window.remileOffline = false;
    window.remileSetOffline = function(offline) {
      window.remileOffline = offline;
      for (const image of document.querySelectorAll('img[data-remote-src]')) {
        const box = image.closest('.remote-image'), hint = box?.querySelector('.image-placeholder');
        if (!box) continue;
        if (offline) {
          box.dataset.offline = 'true'; delete box.dataset.loaded;
          image.removeAttribute('src'); if (hint) hint.textContent = 'Image unavailable offline';
        } else if (box.dataset.offline || !image.hasAttribute('src')) {
          delete box.dataset.offline; delete box.dataset.failed;
          if (hint) hint.textContent = 'Loading image…'; image.src = image.dataset.remoteSrc;
        } else if (image.complete && image.naturalWidth > 0) { box.dataset.loaded = 'true'; }
      }
    };
    document.addEventListener('load', function(event) {
      const image = event.target;
      if (image.tagName === 'IMG' && image.dataset.remoteSrc && image.naturalWidth > 0) {
        const box = image.closest('.remote-image'); if (box && !window.remileOffline) { box.dataset.loaded = 'true'; delete box.dataset.failed; }
      }
    }, true);
    document.addEventListener('error', function(event) {
      const image = event.target;
      if (image.tagName === 'IMG' && image.dataset.remoteSrc) {
        const box = image.closest('.remote-image'), hint = box?.querySelector('.image-placeholder');
        if (box) { box.dataset.failed = 'true'; delete box.dataset.loaded; }
        if (hint) hint.textContent = window.remileOffline ? 'Image unavailable offline' : 'Image unavailable';
      }
    }, true);

    """
}
