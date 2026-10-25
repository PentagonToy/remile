import Foundation

/// Credentials go only to Overleaf's existing HTTPS form, with its own CSRF and verification flow.
enum OverleafLoginForm {
    static func trusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && ["www.overleaf.com", "overleaf.com"].contains(url.host?.lowercased() ?? "") && ["/login", "/user/login"].contains(url.path)
    }
    static let inspect = #"""
    const email = document.querySelector('input[name="email"]');
    const password = document.querySelector('input[name="password"]');
    return !!(email && password && email.form && email.form === password.form);
    """#
    static let submit = #"""
    if (location.protocol !== 'https:' || (location.port && location.port !== '443') || !['www.overleaf.com', 'overleaf.com'].includes(location.hostname) || !['/login', '/user/login'].includes(location.pathname)) return 'browser';
    const emailField = document.querySelector('input[name="email"]');
    const passwordField = document.querySelector('input[name="password"]');
    const form = passwordField?.form;
    if (!form || emailField?.form !== form || passwordField.type !== 'password') return 'browser';
    const button = form.querySelector('button[type="submit"], input[type="submit"]');
    const action = new URL(button?.hasAttribute('formaction') ? button.formAction : form.action, location.href);
    const method = button?.hasAttribute('formmethod') ? button.formMethod : form.method;
    const target = button?.hasAttribute('formtarget') ? button.formTarget : form.target;
    if (action.origin !== location.origin || !['/login', '/user/login'].includes(action.pathname) || method.toLowerCase() !== 'post' || (target && target !== '_self')) return 'browser';
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    for (const [field, value] of [[emailField, email], [passwordField, password]]) {
      setter.call(field, value);
      field.dispatchEvent(new Event('input', {bubbles: true}));
      field.dispatchEvent(new Event('change', {bubbles: true}));
    }
    if (!form.checkValidity()) return 'browser';
    HTMLFormElement.prototype.requestSubmit.call(form, button || undefined);
    return 'submitted';
    """#
    static let observe = #"""
    (() => {
      if (location.protocol !== 'https:' || (location.port && location.port !== '443') || !['www.overleaf.com', 'overleaf.com'].includes(location.hostname)) return;
      let sent = false;
      const visible = node => !!(node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden');
      const check = () => {
        if (sent) return;
        const error = [...document.querySelectorAll('[role="alert"], .alert-danger, .notification-error')].some(n => visible(n) && n.textContent.trim().length);
        const challenge = [...document.querySelectorAll('iframe[src*="bframe"], iframe[src*="hcaptcha"], input[autocomplete="one-time-code"]')].some(visible);
        if (error || challenge) { sent = true; window.webkit.messageHandlers.remileLogin.postMessage('browser'); }
      };
      new MutationObserver(check).observe(document.documentElement, {childList: true, subtree: true, attributes: true, characterData: true});
      check();
    })();
    """#
}
