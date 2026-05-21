allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    val injectNamespace = {
        if (project.plugins.hasPlugin("com.android.library") || project.plugins.hasPlugin("com.android.application")) {
            val android = project.extensions.findByName("android")
            if (android != null) {
                try {
                    val getNamespace = android.javaClass.methods.firstOrNull { it.name == "getNamespace" }
                    val setNamespace = android.javaClass.methods.firstOrNull { it.name == "setNamespace" && it.parameterTypes.size == 1 && it.parameterTypes[0] == String::class.java }
                    if (getNamespace != null && setNamespace != null) {
                        val currentNamespace = getNamespace.invoke(android)
                        if (currentNamespace == null || (currentNamespace as? String)?.isEmpty() == true) {
                            var ns = "com.koda.${project.name.replace("-", ".").replace("_", ".")}"
                            val manifestFile = project.file("src/main/AndroidManifest.xml")
                            if (manifestFile.exists()) {
                                val manifestText = manifestFile.readText()
                                val matcher = java.util.regex.Pattern.compile("package=\"([^\"]+)\"").matcher(manifestText)
                                if (matcher.find()) {
                                    ns = matcher.group(1)
                                }
                            }
                            setNamespace.invoke(android, ns)
                        }
                    }
                } catch (e: Exception) {
                    // Ignore errors during dynamic namespace injection
                }
            }
        }
    }

    if (project.state.executed) {
        injectNamespace()
    } else {
        project.afterEvaluate {
            injectNamespace()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
