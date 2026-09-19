if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js', { scope: '/' })
        .then(registration => {
            console.log('Service Worker registered:', registration);

            // Check for updates periodically
            setInterval(() => {
                registration.update();
            }, 60000); // Check every 60 seconds

            // Listen for service worker updates
            registration.addEventListener('updatefound', () => {
                const newWorker = registration.installing;
                newWorker.addEventListener('statechange', () => {
                    if (newWorker.state === 'installed' && navigator.serviceWorker.controller) {
                        // New service worker is ready
                        console.log('Service Worker update available');
                    }
                });
            });
        })
        .catch(error => {
            console.error('Service Worker registration failed:', error);
        });
}
