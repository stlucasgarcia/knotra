const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

// Keep the timeline pinned to the newest message unless the reader scrolled up.
const ChatScroll = {
  mounted() {
    this.atBottom = true;
    this.scroll();
  },
  beforeUpdate() {
    this.atBottom =
      this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 120;
  },
  updated() {
    if (this.atBottom) this.scroll();
  },
  scroll() {
    this.el.scrollTop = this.el.scrollHeight;
  }
};

// Enter sends; Shift+Enter adds a newline.
const Composer = {
  mounted() {
    this.el.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        this.el.form.requestSubmit();
      }
    });
  }
};

const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {ChatScroll, Composer}
});

liveSocket.connect();
