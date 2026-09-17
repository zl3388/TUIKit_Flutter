package com.tencent.application

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "offline_demo/source_directory"
        private const val PICK_DIRECTORY_REQUEST = 0x5701
    }

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleSourceDirectoryCall)
    }

    private fun handleSourceDirectoryCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDirectory" -> pickDirectory(result)
            "materializeDirectory" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrBlank()) {
                    result.error("invalid_uri", "Directory URI is missing", null)
                } else {
                    materializeDirectory(uri, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error("picker_active", "A directory picker is already active", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_DIRECTORY_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingDirectoryResult
        pendingDirectoryResult = null
        if (result == null) {
            return
        }
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            result.success(uri.toString())
        } catch (error: SecurityException) {
            result.error("permission_denied", "Directory permission was not retained", null)
        }
    }

    private fun materializeDirectory(locator: String, result: MethodChannel.Result) {
        ioExecutor.execute {
            try {
                val path = createStableMirror(Uri.parse(locator))
                mainHandler.post { result.success(path) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "materialize_failed",
                        error.message ?: "Directory could not be read",
                        null,
                    )
                }
            }
        }
    }

    private fun createStableMirror(treeUri: Uri): String {
        val mirrorRoot = File(cacheDir, "offline_source_mirrors")
        if (!mirrorRoot.exists() && !mirrorRoot.mkdirs()) {
            throw IOException("Could not create source mirror root")
        }
        val key = sha256(treeUri.toString().toByteArray())
        val target = File(mirrorRoot, key)

        repeat(2) { attempt ->
            val before = enumerateImportEntries(treeUri)
            val temporary = File(mirrorRoot, "$key.tmp")
            temporary.deleteRecursively()
            if (!temporary.mkdirs()) {
                throw IOException("Could not create temporary source mirror")
            }
            val copiedHashes = copyEntries(before, temporary)
            val after = enumerateImportEntries(treeUri)
            val stable = entrySignatures(before) == entrySignatures(after) &&
                after.filterNot { it.isDirectory }.all { entry ->
                    copiedHashes[entry.relativePath] == hashDocument(entry.uri)
                }
            if (stable) {
                target.deleteRecursively()
                if (!temporary.renameTo(target)) {
                    temporary.copyRecursively(target, overwrite = true)
                    temporary.deleteRecursively()
                }
                return target.absolutePath
            }
            temporary.deleteRecursively()
            if (attempt == 1) {
                throw IOException("Source directory changed during import")
            }
        }
        throw IOException("Source directory could not be materialized")
    }

    private fun enumerateImportEntries(treeUri: Uri): List<DocumentEntry> {
        val root = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val children = listChildren(treeUri, root)
        val dataDirectory = children.singleOrNull {
            it.isDirectory && it.displayName == "Data"
        }
        val entries = mutableListOf<DocumentEntry>()
        if (dataDirectory != null) {
            entries += dataDirectory.copy(relativePath = "Data")
            enumerateChildren(treeUri, dataDirectory.uri, "Data", entries)
            children.singleOrNull {
                !it.isDirectory && it.displayName == "Config.cfg"
            }?.let { entries += it.copy(relativePath = "Config.cfg") }
        } else {
            if (documentDisplayName(root) != "Data") {
                throw IOException("Select an account root or its Data directory")
            }
            entries += DocumentEntry(
                relativePath = "Data",
                displayName = "Data",
                uri = root,
                mimeType = DocumentsContract.Document.MIME_TYPE_DIR,
                size = -1,
                lastModified = -1,
            )
            enumerateChildren(treeUri, root, "Data", entries)
        }
        return entries.sortedBy { it.relativePath }
    }

    private fun documentDisplayName(documentUri: Uri): String {
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        contentResolver.query(documentUri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val name = cursor.getString(0) ?: ""
                validateName(name)
                return name
            }
        }
        throw IOException("Directory provider returned no root document")
    }

    private fun enumerateChildren(
        treeUri: Uri,
        parentUri: Uri,
        parentPath: String,
        output: MutableList<DocumentEntry>,
    ) {
        for (child in listChildren(treeUri, parentUri)) {
            val relativePath = "$parentPath/${child.displayName}"
            val entry = child.copy(relativePath = relativePath)
            output += entry
            if (entry.isDirectory) {
                enumerateChildren(treeUri, entry.uri, relativePath, output)
            }
        }
    }

    private fun listChildren(treeUri: Uri, parentUri: Uri): List<DocumentEntry> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(parentUri),
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val entries = mutableListOf<DocumentEntry>()
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            val mimeIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            val sizeIndex = cursor.getColumnIndex(
                DocumentsContract.Document.COLUMN_SIZE,
            )
            val modifiedIndex = cursor.getColumnIndex(
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(idIndex)
                val displayName = cursor.getString(nameIndex) ?: ""
                validateName(displayName)
                entries += DocumentEntry(
                    relativePath = displayName,
                    displayName = displayName,
                    uri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        documentId,
                    ),
                    mimeType = cursor.getString(mimeIndex),
                    size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        cursor.getLong(sizeIndex)
                    } else {
                        -1
                    },
                    lastModified = if (
                        modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)
                    ) {
                        cursor.getLong(modifiedIndex)
                    } else {
                        -1
                    },
                )
            }
        } ?: throw IOException("Directory provider returned no cursor")
        return entries
    }

    private fun copyEntries(
        entries: List<DocumentEntry>,
        destination: File,
    ): Map<String, String> {
        val destinationRoot = destination.canonicalFile
        val hashes = mutableMapOf<String, String>()
        for (entry in entries) {
            val output = File(destinationRoot, entry.relativePath).canonicalFile
            if (output != destinationRoot &&
                !output.path.startsWith(destinationRoot.path + File.separator)
            ) {
                throw IOException("Invalid source entry path")
            }
            if (entry.isDirectory) {
                if (!output.exists() && !output.mkdirs()) {
                    throw IOException("Could not create mirrored directory")
                }
                continue
            }
            output.parentFile?.mkdirs()
            val digest = MessageDigest.getInstance("SHA-256")
            val input = contentResolver.openInputStream(entry.uri)
                ?: throw IOException("Source file could not be opened")
            input.use { stream ->
                FileOutputStream(output).use { target ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        target.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                    }
                    target.fd.sync()
                }
            }
            hashes[entry.relativePath] = digest.digest().toHex()
        }
        return hashes
    }

    private fun hashDocument(uri: Uri): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val input = contentResolver.openInputStream(uri)
            ?: throw IOException("Source file could not be reopened")
        input.use { stream ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().toHex()
    }

    private fun entrySignatures(entries: List<DocumentEntry>): List<String> =
        entries.map {
            "${it.relativePath}\u0000${it.mimeType}\u0000${it.size}\u0000${it.lastModified}"
        }

    private fun validateName(name: String) {
        if (name.isBlank() || name == "." || name == ".." ||
            name.contains('/') || name.contains('\\') || name.contains('\u0000')
        ) {
            throw IOException("Directory provider returned an invalid name")
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it.toInt() and 0xff) }

    override fun onDestroy() {
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private data class DocumentEntry(
        val relativePath: String,
        val displayName: String,
        val uri: Uri,
        val mimeType: String,
        val size: Long,
        val lastModified: Long,
    ) {
        val isDirectory: Boolean
            get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    }
}
