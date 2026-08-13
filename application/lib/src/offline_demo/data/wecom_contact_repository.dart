import '../domain/models.dart';
import '../domain/repositories.dart';
import 'wecom_merged_directory_repository.dart';

class WeComContactRepository implements ContactRepository {
  const WeComContactRepository(this._directory);

  final WeComMergedDirectoryRepository _directory;

  @override
  bool get isAvailable => true;

  @override
  Future<List<DirectoryContact>> listContacts() async {
    final contacts = await _directory.listAllInternalContacts();
    return contacts
        .map(
          (contact) => DirectoryContact(
            id: contact.id.toString(),
            displayName: contact.displayName,
            account: _nonEmpty(contact.account),
            organizationName: _nonEmpty(contact.externalCorporationName),
            jobTitle: _nonEmpty(contact.externalJob),
          ),
        )
        .toList(growable: false);
  }

  String? _nonEmpty(String? value) {
    return value == null || value.isEmpty ? null : value;
  }
}
