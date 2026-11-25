using System.Runtime.InteropServices;
using UnityEngine;

namespace MaciPEAK
{
    public sealed class DisplaySync : MonoBehaviour
    {
        [DllImport("MaciPEAKDisplaySync")]
        private static extern int macipeak_apply_display_sync(int enabled);

        private SettingsHandler handler;
        private VSyncSetting setting;
        private bool lastEnabled;
        private double nextLayerCheck;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Initialize()
        {
            var host = new GameObject("MaciPEAK display sync");
            DontDestroyOnLoad(host);
            host.AddComponent<DisplaySync>();
        }

        private void LateUpdate()
        {
            // PEAK resolves its saved settings and first-launch defaults in the constructor.
            var current = SettingsHandler.Instance;
            if (current == null)
                return;
            if (current != handler || setting == null)
            {
                handler = current;
                setting = current.GetSetting<VSyncSetting>();
                nextLayerCheck = 0;
            }
            if (setting == null)
                return;

            bool enabled = setting.Value == VSyncSetting.VSyncMode.Enabled;
            // This Unity player's direct presentation path needs the system timer for
            // physics and networking. The Metal layer performs the requested VSync.
            bool unityChanged = QualitySettings.vSyncCount != 0;
            if (unityChanged)
                QualitySettings.vSyncCount = 0;

            double now = Time.realtimeSinceStartupAsDouble;
            if (!unityChanged && enabled == lastEnabled && now < nextLayerCheck)
                return;

            // Unity can recreate the layer across fullscreen or display changes.
            int applied = macipeak_apply_display_sync(enabled ? 1 : 0);
            lastEnabled = enabled;
            nextLayerCheck = now + (applied == 1 ? 0.5 : 0.2);
        }
    }
}
