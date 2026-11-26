using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;

public static class UnityAabWorkflowBridge
{
    public static void Run()
    {
        string outputPath = ResolveOutputPath();
        string[] scenes = EditorBuildSettings.scenes
            .Where(scene => scene.enabled && !string.IsNullOrEmpty(scene.path))
            .Select(scene => scene.path)
            .ToArray();

        if (scenes.Length == 0)
        {
            throw new BuildFailedException("Enable at least one scene in EditorBuildSettings before building AAB.");
        }

        NamedBuildTarget androidTarget = NamedBuildTarget.Android;

        bool prevBuildAppBundle = EditorUserBuildSettings.buildAppBundle;
        bool prevUseCustomKeystore = PlayerSettings.Android.useCustomKeystore;
        ScriptingImplementation prevBackend = PlayerSettings.GetScriptingBackend(androidTarget);
        AndroidArchitecture prevArchitectures = PlayerSettings.Android.targetArchitectures;
        AndroidSdkVersions prevMinSdk = PlayerSettings.Android.minSdkVersion;
        AndroidSdkVersions prevTargetSdk = PlayerSettings.Android.targetSdkVersion;
        string prevBundleVersion = PlayerSettings.bundleVersion;
        int prevVersionCode = PlayerSettings.Android.bundleVersionCode;
        string prevAppId = PlayerSettings.GetApplicationIdentifier(androidTarget);

        try
        {
            string pkgOverride = Environment.GetEnvironmentVariable("UNITY_AAB_PACKAGE_NAME");
            if (!string.IsNullOrWhiteSpace(pkgOverride))
            {
                PlayerSettings.SetApplicationIdentifier(androidTarget, pkgOverride.Trim());
            }

            string versionNameOverride = Environment.GetEnvironmentVariable("UNITY_AAB_VERSION_NAME");
            if (!string.IsNullOrWhiteSpace(versionNameOverride))
            {
                PlayerSettings.bundleVersion = versionNameOverride.Trim();
            }

            string versionCodeOverride = Environment.GetEnvironmentVariable("UNITY_AAB_VERSION_CODE");
            int parsedVersionCode;
            if (!string.IsNullOrWhiteSpace(versionCodeOverride) && int.TryParse(versionCodeOverride.Trim(), out parsedVersionCode) && parsedVersionCode > 0)
            {
                PlayerSettings.Android.bundleVersionCode = parsedVersionCode;
            }

            string minSdkOverride = Environment.GetEnvironmentVariable("UNITY_AAB_MIN_SDK");
            int parsedMinSdk;
            if (!string.IsNullOrWhiteSpace(minSdkOverride) && int.TryParse(minSdkOverride.Trim(), out parsedMinSdk) && parsedMinSdk > 0)
            {
                PlayerSettings.Android.minSdkVersion = (AndroidSdkVersions)parsedMinSdk;
            }

            string targetSdkOverride = Environment.GetEnvironmentVariable("UNITY_AAB_TARGET_SDK");
            int parsedTargetSdk;
            if (!string.IsNullOrWhiteSpace(targetSdkOverride) && int.TryParse(targetSdkOverride.Trim(), out parsedTargetSdk) && parsedTargetSdk > 0)
            {
                PlayerSettings.Android.targetSdkVersion = (AndroidSdkVersions)parsedTargetSdk;
            }

            PlayerSettings.SetScriptingBackend(androidTarget, ScriptingImplementation.IL2CPP);
            PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
            PlayerSettings.Android.useCustomKeystore = false;
            EditorUserBuildSettings.buildAppBundle = true;

            string parentDir = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrEmpty(parentDir))
            {
                Directory.CreateDirectory(parentDir);
            }
            if (File.Exists(outputPath))
            {
                File.Delete(outputPath);
            }

            BuildReport report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
            {
                scenes = scenes,
                locationPathName = outputPath,
                target = BuildTarget.Android,
                options = BuildOptions.None
            });

            if (report.summary.result != BuildResult.Succeeded)
            {
                if (File.Exists(outputPath))
                {
                    File.Delete(outputPath);
                }
                throw new BuildFailedException(
                    "Android AAB build failed: " + report.summary.result + " (" + report.summary.totalErrors + " errors).");
            }

            if (!File.Exists(outputPath))
            {
                throw new BuildFailedException("Unity reported build success, but AAB file was not found at: " + outputPath);
            }
        }
        finally
        {
            EditorUserBuildSettings.buildAppBundle = prevBuildAppBundle;
            PlayerSettings.Android.useCustomKeystore = prevUseCustomKeystore;
            PlayerSettings.SetScriptingBackend(androidTarget, prevBackend);
            PlayerSettings.Android.targetArchitectures = prevArchitectures;
            PlayerSettings.Android.minSdkVersion = prevMinSdk;
            PlayerSettings.Android.targetSdkVersion = prevTargetSdk;
            PlayerSettings.bundleVersion = prevBundleVersion;
            PlayerSettings.Android.bundleVersionCode = prevVersionCode;
            PlayerSettings.SetApplicationIdentifier(androidTarget, prevAppId);
        }
    }

    private static string ResolveOutputPath()
    {
        string[] args = Environment.GetCommandLineArgs();
        int idx = Array.IndexOf(args, "-buildOutput");
        string candidate = (idx >= 0 && idx + 1 < args.Length)
            ? args[idx + 1]
            : Environment.GetEnvironmentVariable("UNITY_AAB_OUTPUT");

        if (string.IsNullOrWhiteSpace(candidate))
        {
            throw new BuildFailedException("Provide an .aab output path via -buildOutput (Unity CLI --output-path) or UNITY_AAB_OUTPUT.");
        }

        string fullPath = Path.GetFullPath(candidate.Trim());
        if (!string.Equals(Path.GetExtension(fullPath), ".aab", StringComparison.OrdinalIgnoreCase))
        {
            throw new BuildFailedException("Output path must end with .aab: " + fullPath);
        }

        return fullPath;
    }
}
