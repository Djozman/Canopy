# Contract: Rename Validation

**Layer**: PreAddViewModel (Swift)

## Function Signature

```swift
enum RenameValidationError: Equatable {
    case empty
    case illegalCharacter(Character)
    case duplicateSibling
}

func validateRename(
    _ newName: String,
    in parent: FileNode?
) -> RenameValidationError?
```

- `newName` must be non-empty and contain no `/` or other macOS-illegal
  filename characters (`CharacterSet(charactersIn: "/:")` plus control/null).
- `parent` is the node's containing folder; the new name must not collide with
  another child of the same type (file vs file, folder vs folder).

## Inline Error UX

On a validate error, reject the change, keep the original name, and surface a
human-readable inline message, e.g.:
- "Name cannot be empty."
- "Name contains an illegal character: `/`" 
- "A file/folder with this name already exists in this folder."

Errors render inline within 1 second (SC-003).