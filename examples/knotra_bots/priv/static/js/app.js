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

// Enter sends; Shift+Enter adds a newline. While the @ mention list is open,
// ArrowUp/ArrowDown move the selection, Tab or Enter picks it, and Escape
// dismisses the list. A picked mention updates the draft server-side; because
// the textarea is focused and already edited, the browser keeps its value, so
// copy the new draft when the mention revision changes.
const Composer = {
  mounted() {
    this.revision = this.el.dataset.mentionRevision;
    this.pickValue = null;

    this.el.addEventListener("keydown", (event) => {
      // Let the IME own composition keys, including conversion navigation.
      if (event.isComposing || event.keyCode === 229) return;

      const menu = document.querySelector(".mention-menu");

      if (!menu || menu.hidden) {
        if (event.key === "Enter" && !event.shiftKey) {
          event.preventDefault();
          this.el.form.requestSubmit();
        }
        return;
      }

      const options = Array.from(menu.querySelectorAll(".mention-option"));
      if (options.length === 0) return;

      const current = options.findIndex((option) => option.classList.contains("is-active"));
      const chosen = options[current < 0 ? 0 : current];

      if (event.key === "ArrowDown") {
        event.preventDefault();
        this.select(options, current < 0 ? 0 : (current + 1) % options.length);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        this.select(
          options,
          current < 0 ? options.length - 1 : (current - 1 + options.length) % options.length
        );
      } else if (event.key === "Tab" && !event.shiftKey) {
        event.preventDefault();
        this.rememberPick();
        chosen.click();
      } else if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        this.rememberPick();
        chosen.click();
      } else if (event.key === "Escape") {
        event.preventDefault();
        menu.hidden = true;
        this.el.setAttribute("aria-expanded", "false");
        this.el.removeAttribute("aria-activedescendant");
        this.pushEvent("dismiss_mentions", {});
      }
    });

    // Picking with the mouse bypasses the keydown path; remember the draft so a
    // response never overwrites text typed while the pick was in flight.
    this.onOptionClick = (event) => {
      if (event.target.closest(".mention-option")) this.rememberPick();
    };

    document.addEventListener("click", this.onOptionClick);

    // Typing again reopens a list dismissed with Escape.
    this.onInput = () => {
      const menu = document.querySelector(".mention-menu");
      if (menu) menu.hidden = false;
    };

    this.el.addEventListener("input", this.onInput);
  },

  destroyed() {
    document.removeEventListener("click", this.onOptionClick);
    this.el.removeEventListener("input", this.onInput);
  },

  rememberPick() {
    this.pickValue = this.el.value;
  },

  select(options, index) {
    options.forEach((option, i) => {
      option.classList.toggle("is-active", i === index);
      option.setAttribute("aria-selected", i === index ? "true" : "false");
    });

    if (options[index].id) {
      this.el.setAttribute("aria-activedescendant", options[index].id);
    }

    options[index].scrollIntoView({ block: "nearest" });
  },

  updated() {
    const revision = this.el.dataset.mentionRevision;

    if (revision !== this.revision) {
      this.revision = revision;

      const expected = this.pickValue;
      this.pickValue = null;

      if (expected !== null) {
        if (this.el.value === expected) {
          this.el.value = this.el.dataset.draft;
        } else if (this.el.value.startsWith(expected)) {
          // The user typed after the token while the pick was in flight. Keep
          // that suffix and sync the merged draft so the server matches.
          this.el.value = this.el.dataset.draft + this.el.value.slice(expected.length);
          this.el.dispatchEvent(new Event("input", { bubbles: true }));
        }
      }

      this.el.focus();
    }

    // Keep the announced option valid when a response replaces the list and
    // removes the previously highlighted node.
    const menu = document.querySelector(".mention-menu");

    if (menu && !menu.hidden) {
      const options = Array.from(menu.querySelectorAll(".mention-option"));

      if (options.length > 0 && !options.some((option) => option.classList.contains("is-active"))) {
        this.select(options, 0);
      }
    }
  }
};

const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {ChatScroll, Composer}
});

liveSocket.connect();
