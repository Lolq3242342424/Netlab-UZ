"use strict";

/* NetLab UZ — Stage C: synchronous theme bootstrap.
   Runs BEFORE stylesheets. Applies [data-theme] to <html> to prevent FOUC.
   Must stay in sync with static/theme.js:
     - same STORAGE_KEY
     - same THEMES list
     - same systemTheme() semantics
   No inline scripts, no eval, no innerHTML, no style=. */

(function () {
    var STORAGE_KEY = 'netlab.theme';
    var THEMES = ['cyberpunk', 'ocean', 'purple', 'emerald', 'crimson', 'light'];
    var FALLBACK_DARK = 'cyberpunk';
    var FALLBACK_LIGHT = 'light';

    function safeGet() {
        try { return localStorage.getItem(STORAGE_KEY); } catch (e) { return null; }
    }

    function systemTheme() {
        try {
            if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
                return FALLBACK_LIGHT;
            }
        } catch (e) { /* matchMedia unavailable — fall through */ }
        return FALLBACK_DARK;
    }

    var saved = safeGet();
    var theme = (saved && THEMES.indexOf(saved) >= 0) ? saved : systemTheme();
    document.documentElement.setAttribute('data-theme', theme);
})();