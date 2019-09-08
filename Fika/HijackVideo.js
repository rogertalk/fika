// This script will notify the app when a web page attempts to play audio or video.
(() => {
    function notifyPlay(video) {
        const rect = video.getBoundingClientRect();
        window.webkit.messageHandlers.fika.postMessage({
            type: 'play',
            frame: {
                x: window.scrollX + rect.left,
                y: window.scrollY + rect.top,
                width: rect.width,
                height: rect.height,
            },
            src: video.src,
        });
    }

    const fakePlay = new CustomEvent('play');
    HTMLMediaElement.prototype.play = function () {
        notifyPlay(this);
        this.dispatchEvent(fakePlay);
    };

    document.addEventListener('play', e => {
        if (e === fakePlay) return;
        e.target.pause();
        notifyPlay(e.target);
    }, true);
})();
