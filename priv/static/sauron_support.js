// SauronReporter.Support — the support card's one hook (Sauron plan 29).
//
// The card works without it; with it, what a server cannot do:
//
//   * place (0.9.0): the card opens under the app's own button — the
//     component's `anchor` (a CSS selector), else the button that ran
//     `open_panel()`/`toggle_panel()` (they dispatch
//     `sauron-support:trigger` from it) — aligned to its right edge, a
//     pointer towards it, and follows it on resize and scroll. On a
//     phone the stylesheet makes it a bottom sheet; with the slip, it
//     stays above the slip. The position goes to <html> as CSS
//     variables (--aide-at-top, --aide-at-right, --aide-at-pointer,
//     --aide-at-pointer-shown): the LiveView never patches <html>;
//   * tell the page (0.9.0), on window: `sauron-support:open` and
//     `sauron-support:close` (detail: {id, trigger}) when the card opens
//     and closes; and listen, on window, to `sauron-support:close-request`
//     (the app's script) and `phx:sauron-support:close-request` (the
//     app's server, `push_event/3`) — one drawer open at a time;
//   * Échap closes it from its button too, and the focus goes back to
//     the button when the card closes with the focus inside it;
//   * paste: an image pasted into the card (Ctrl V of a screenshot)
//     is attached, as if chosen with the paperclip;
//   * capture: « Capturer cet écran » / « Capture » asks the browser to
//     share a screen or a tab (getDisplayMedia), keeps one frame as a
//     PNG and attaches it — the buttons only appear where the browser
//     can do it;
//   * Enter sends the message, Shift+Enter makes a new line.
//
// Register it with the app's LiveSocket:
//
//   import {SauronSupport} from "../../deps/sauron_reporter/priv/static/sauron_support.js"
//   let liveSocket = new LiveSocket("/live", Socket, {hooks: {SauronSupport, ...}, ...})
//
// The files go through the LiveView's upload (`this.upload`), to the
// app's server, never to Sauron from the browser.

const UPLOAD = "files"
const GAP = 10 // px between the button and the card
const EDGE = 16 // px kept free at the window's edges
const VARS = ["--aide-at-top", "--aide-at-right", "--aide-at-pointer", "--aide-at-pointer-shown"]

export const SauronSupport = {
  mounted() {
    this.id = this.el.dataset.panel
    this.open = false
    this.trigger = null
    this.canCapture = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia)
    this.pushEvent("capabilities", {capture: this.canCapture})

    this.onPaste = (event) => {
      const files = Array.from((event.clipboardData && event.clipboardData.files) || [])
        .filter((file) => file.type.startsWith("image/"))
      if (files.length === 0 || !this.el.querySelector(`input[type=file][name="${UPLOAD}"]`)) return
      event.preventDefault()
      this.upload(UPLOAD, files)
    }

    this.onCapture = () => this.capture()

    this.onKeydown = (event) => {
      const field = event.target
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
      if (!(field instanceof HTMLTextAreaElement) || !field.hasAttribute("data-aide-enter")) return
      event.preventDefault()
      if (field.form) field.form.requestSubmit()
    }

    // The button the app clicked: where to open when no anchor is named.
    this.onTrigger = (event) => {
      if (!event.detail || event.detail.id === this.id) this.trigger = event.target
    }

    this.onCloseRequest = () => {
      if (this.open) this.pushEvent("close_panel", {})
    }

    // Échap on the button (inside the card, the card's own phx-keydown).
    this.onWindowKey = (event) => {
      if (event.key !== "Escape" || !this.open || this.el.contains(event.target)) return
      const anchor = this.anchor()
      if (anchor && (event.target === anchor || anchor.contains(event.target))) {
        this.pushEvent("close_panel", {})
      }
    }

    this.onMove = () => {
      if (!this.open || this.frame) return
      this.frame = requestAnimationFrame(() => {
        this.frame = null
        this.place()
      })
    }

    this.el.addEventListener("paste", this.onPaste)
    this.el.addEventListener("sauron:capture", this.onCapture)
    this.el.addEventListener("keydown", this.onKeydown)
    window.addEventListener("sauron-support:trigger", this.onTrigger)
    window.addEventListener("sauron-support:close-request", this.onCloseRequest)
    window.addEventListener("phx:sauron-support:close-request", this.onCloseRequest)
    window.addEventListener("keydown", this.onWindowKey)
    window.addEventListener("resize", this.onMove, {passive: true})
    window.addEventListener("scroll", this.onMove, {passive: true, capture: true})

    // The card comes and goes as the server renders it.
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.el, {childList: true})
    this.sync()
  },

  reconnected() {
    this.pushEvent("capabilities", {capture: this.canCapture})
  },

  destroyed() {
    this.observer.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
    this.el.removeEventListener("paste", this.onPaste)
    this.el.removeEventListener("sauron:capture", this.onCapture)
    this.el.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("sauron-support:trigger", this.onTrigger)
    window.removeEventListener("sauron-support:close-request", this.onCloseRequest)
    window.removeEventListener("phx:sauron-support:close-request", this.onCloseRequest)
    window.removeEventListener("keydown", this.onWindowKey)
    window.removeEventListener("resize", this.onMove, {passive: true})
    window.removeEventListener("scroll", this.onMove, {passive: true, capture: true})
    this.clear()
    if (this.open) this.tell("sauron-support:close")
  },

  card() {
    return this.el.querySelector(":scope > .aide-card")
  },

  // The named anchor when it is on screen, else the button clicked.
  anchor() {
    const shown = (el) => el && el.isConnected && el.getClientRects().length > 0
    let named = null
    try {
      named = this.el.dataset.anchor ? document.querySelector(this.el.dataset.anchor) : null
    } catch (_) {
      named = null // not a selector
    }
    if (shown(named)) return named
    return shown(this.trigger) ? this.trigger : null
  },

  sync() {
    const open = !!this.card()
    if (open === this.open) return
    this.open = open

    if (open) {
      this.place()
      this.tell("sauron-support:open")
    } else {
      this.clear()
      const focus = document.activeElement
      if (!focus || focus === document.body) {
        const anchor = this.anchor()
        if (anchor) anchor.focus({preventScroll: true})
      }
      this.tell("sauron-support:close")
    }
  },

  place() {
    const card = this.card()
    const anchor = this.anchor()
    if (!card || !anchor || card.classList.contains("aide-card-low")) return this.clear()

    const box = anchor.getBoundingClientRect()
    const width = document.documentElement.clientWidth
    const right = Math.max(EDGE, width - box.right)
    const below = box.bottom + GAP
    const top = Math.min(Math.max(below, EDGE), window.innerHeight - 160)
    // From the card's right edge to the pointer's, under the button's middle.
    const cardWidth = card.offsetWidth || 400
    const pointer = Math.min(Math.max(width - right - (box.left + box.width / 2) - 7, 12), cardWidth - 26)
    const style = document.documentElement.style

    style.setProperty("--aide-at-top", `${Math.round(top)}px`)
    style.setProperty("--aide-at-right", `${Math.round(right)}px`)
    style.setProperty("--aide-at-pointer", `${Math.round(pointer)}px`)
    style.setProperty("--aide-at-pointer-shown", top === below ? "visible" : "hidden")
  },

  clear() {
    VARS.forEach((name) => document.documentElement.style.removeProperty(name))
  },

  tell(name) {
    const trigger = this.anchor()
    window.dispatchEvent(new CustomEvent(name, {detail: {id: this.id, trigger}}))
  },

  async capture() {
    let stream
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
        video: {displaySurface: "browser"},
        audio: false,
        preferCurrentTab: true,
      })
      const video = document.createElement("video")
      video.muted = true
      video.srcObject = stream
      await video.play()
      // One frame painted before it is kept.
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
      const canvas = document.createElement("canvas")
      canvas.width = video.videoWidth
      canvas.height = video.videoHeight
      canvas.getContext("2d").drawImage(video, 0, 0)
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"))
      if (!blob) throw new Error("no frame")
      const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")
      this.upload(UPLOAD, [new File([blob], `capture-${stamp}.png`, {type: "image/png"})])
    } catch (error) {
      // The user said no: nothing to say back.
      if (!error || error.name !== "NotAllowedError") this.pushEvent("capture_failed", {})
    } finally {
      if (stream) stream.getTracks().forEach((track) => track.stop())
    }
  },
}

export default {SauronSupport}
