// SauronReporter.Support — the panel's one hook (Sauron plan 29).
//
// The panel works without it; with it, three things a server cannot do:
//
//   * paste: an image pasted into the panel (Ctrl V of a screenshot)
//     is attached, as if chosen with the paperclip;
//   * capture: « Capturer cet écran » / « Capture d'écran » asks the
//     browser to share a screen or a tab (getDisplayMedia), keeps one
//     frame as a PNG and attaches it — the buttons only appear where
//     the browser can do it;
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

export const SauronSupport = {
  mounted() {
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

    this.el.addEventListener("paste", this.onPaste)
    this.el.addEventListener("sauron:capture", this.onCapture)
    this.el.addEventListener("keydown", this.onKeydown)
  },

  reconnected() {
    this.pushEvent("capabilities", {capture: this.canCapture})
  },

  destroyed() {
    this.el.removeEventListener("paste", this.onPaste)
    this.el.removeEventListener("sauron:capture", this.onCapture)
    this.el.removeEventListener("keydown", this.onKeydown)
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
