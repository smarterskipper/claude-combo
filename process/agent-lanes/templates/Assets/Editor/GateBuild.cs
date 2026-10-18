// Assets/Editor/GateBuild.cs: gate build entry point; exits 1 unless the player build succeeds.
using System.Linq; using UnityEditor; using UnityEditor.Build.Reporting; using UnityEngine;
public static class GateBuild {
  public static void BuildPlayer() {
    var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
    var ext = EditorUserBuildSettings.activeBuildTarget == BuildTarget.StandaloneWindows64 ? ".exe" : EditorUserBuildSettings.activeBuildTarget == BuildTarget.StandaloneOSX ? ".app" : "";
    var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions { scenes = scenes, locationPathName = "Build/Gate/Game" + ext, target = EditorUserBuildSettings.activeBuildTarget });
    Debug.Log($"GATE BUILD {report.summary.result} size={report.summary.totalSize} time={report.summary.totalTime}");
    EditorApplication.Exit(report.summary.result == BuildResult.Succeeded ? 0 : 1);
  }
}
