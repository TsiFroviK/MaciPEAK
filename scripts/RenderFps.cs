using System;
using System.Globalization;
using UnityEngine;

namespace MaciPEAK
{
    public sealed class RenderFps : MonoBehaviour
    {
        private double sampleStart;
        private int firstFrame;
        private string reading;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        public static void Initialize()
        {
            if (Array.IndexOf(Environment.GetCommandLineArgs(), "-macipeak-fps") < 0)
                return;

            var host = new GameObject("MaciPEAK render FPS");
            DontDestroyOnLoad(host);
            host.AddComponent<RenderFps>();
        }

        private void OnEnable()
        {
            sampleStart = Time.realtimeSinceStartupAsDouble;
            firstFrame = Time.renderedFrameCount;
        }

        private void Update()
        {
            double now = Time.realtimeSinceStartupAsDouble;
            double elapsed = now - sampleStart;
            if (elapsed < 1.0)
                return;

            int currentFrame = Time.renderedFrameCount;
            double fps = (currentFrame - firstFrame) / elapsed;
            reading = "Unity render FPS  " + fps.ToString("F1", CultureInfo.InvariantCulture);
            firstFrame = currentFrame;
            sampleStart = now;
        }

        private void OnGUI()
        {
            if (reading != null && Event.current.type == EventType.Repaint)
                GUI.Box(new Rect(8, Screen.height - 34, 160, 26), reading);
        }
    }
}
