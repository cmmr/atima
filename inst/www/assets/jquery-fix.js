// Fix from https://stackoverflow.com/a/54663147/3259270
// and https://www.codegrepper.com/code-examples/javascript/frameworks/jquery/how+to+add+make+touchstart+passive+in+jquery+"3.4.0"
// Prevents Google Chrome console message "[Violation] Added non-passive event listener to a scroll-blocking 'touchstart' event. Consider marking event handler as 'passive' to make the page more responsive." when ionRangeSliders are initialized.

jQuery.event.special.touchstart = {
  setup: function (_, ns, handle) {
    this.addEventListener('touchstart', handle, { passive: !ns.includes('noPreventDefault') });
  }
};
jQuery.event.special.touchmove = {
  setup: function (_, ns, handle) {
    this.addEventListener('touchmove', handle, { passive: !ns.includes('noPreventDefault') });
  }
};
