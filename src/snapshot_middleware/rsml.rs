// Modules -------------------------------------------------------------------------------------------
use std::{collections::HashMap, path::Path, str::FromStr};
use sha2::{Sha256, Digest};
use normalize_path::NormalizePath;

use memofs::{IoResultExt, Vfs};

use crate::snapshot::{InstanceContext, InstanceMetadata, InstanceSnapshot};

use super::meta_file::AdjacentMetadata;

use rbx_dom_weak::types::{Attributes, Ref, Variant};

use rbx_rsml::{lex_rsml, parse_rsml, Arena, TokenTreeNode};
// ---------------------------------------------------------------------------------------------------


// Functions -----------------------------------------------------------------------------------------
fn attributes_from_hashmap(variables: &HashMap<&str, Variant>) -> Attributes {
    let mut attributes = Attributes::new();
    if !variables.is_empty() {
        for (key, value) in variables {
            attributes.insert(key.to_string(), value.clone());
        }
    }

    attributes
}

fn apply_token_tree_to_stylesheet_snapshot(
    mut snapshot: InstanceSnapshot, selector: &str, data: &TokenTreeNode, arena: &Arena<TokenTreeNode>
) -> InstanceSnapshot {
    for (selector, children) in &data.rules.0 {
        for child_idx in children {
            let mut style_rule = InstanceSnapshot::new()
            .class_name("StyleRule")
            .name(selector.to_owned());

            let child_data = arena.get(*child_idx).unwrap();
            style_rule = apply_token_tree_to_stylesheet_snapshot(style_rule, &selector, &child_data, &arena);

            snapshot.children.push(style_rule);
        }
    }
    let attributes = attributes_from_hashmap(&data.variables);
    let styled_properties = attributes_from_hashmap(&data.properties);

    let mut properties: HashMap<String, Variant> = HashMap::new();
    properties.insert("Selector".into(), Variant::String(selector.to_string()));
    if let Some(priority) = data.priority { properties.insert("Priority".into(), Variant::Int32(priority)); }
    if !attributes.is_empty() { properties.insert("Attributes".into(), attributes.into()); }
    if !styled_properties.is_empty() { properties.insert("StyledProperties".into(), styled_properties.into()); }


    snapshot.properties(properties)
}
// ---------------------------------------------------------------------------------------------------


fn path_to_ref_string(seed: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(seed);
    let hash = hasher.finalize();

    format!("{:032x}", u128::from_be_bytes(hash[..16].try_into().unwrap()))
}

pub fn snapshot_rsml<'a>(
    context: &InstanceContext,
    vfs: &Vfs,
    path: &Path,
    name: &str
) -> anyhow::Result<Option<InstanceSnapshot>> {
    let contents = vfs.read_to_string(path)?;
    let contents_str = contents.as_str();

    let tokens = lex_rsml(contents_str);
    let token_tree_arena = parse_rsml(&tokens);

    let meta_path = path.with_file_name(format!("{}.meta.json", name));

    let root_node = &token_tree_arena.get(0).unwrap();

    let derives = &root_node.derives.iter()
        .map(|x| {
            match x.starts_with("./") {
                true => path.join("..").join(Path::new(x)).normalize().to_str().unwrap().to_string(),
                false => Path::new(x).normalize().to_str().unwrap().to_string()
            }
        })
        .collect::<Vec<String>>();

    let path_as_ref_string = path_to_ref_string(path.normalize().to_str().unwrap());

    let mut snapshot = InstanceSnapshot::new()
        .name(name)
        .class_name("StyleSheet")
        .snapshot_id(Ref::from_str(&path_as_ref_string).unwrap())
        .metadata(
            InstanceMetadata::new()
                .instigating_source(path)
                .relevant_paths([path.to_path_buf(), meta_path.clone()].into())
                .context(context)
        );

    if let Some(meta_contents) = vfs.read(&meta_path).with_not_found()? {
        let mut metadata = AdjacentMetadata::from_slice(&meta_contents, meta_path)?;
        metadata.apply_all(&mut snapshot)?;
    }

    let root_attributes = attributes_from_hashmap(&root_node.variables);

    snapshot = snapshot.properties([
        ("Attributes".into(), root_attributes.into()),
    ]);

    for (selector, children) in &root_node.rules.0 {
        for child_idx in children {
            let mut rule_snapshot = InstanceSnapshot::new()
            .class_name("StyleRule")
            .name(selector.to_owned());

            rule_snapshot = apply_token_tree_to_stylesheet_snapshot(
                rule_snapshot, selector, &token_tree_arena.get(child_idx.to_owned()).unwrap(), &token_tree_arena
            );

            snapshot.children.push(rule_snapshot);
        }
    }

    for path in derives {
        let name = match Path::new(path).file_stem() {
            Some(file_stem) => match file_stem.to_str() {
                Some(file) => &format!("{} (Derive)", file),
                None => "StyleDerive"
            },
            None => "StyleDerive"
        };

        snapshot.children.push(
            InstanceSnapshot::new()
                .name(name)
                .class_name("StyleDerive")
                .properties([
                    ("StyleSheet".into(), Variant::Ref(Ref::from_str(&path_to_ref_string(path)).unwrap()))
                ])
        );
    }

    Ok(Some(snapshot))
}


#[cfg(test)]
mod test {
    use super::*;

    use memofs::{InMemoryFs, VfsSnapshot};

    #[test]
    fn instance_from_vfs() {
        let mut imfs = InMemoryFs::new();
        imfs.load_snapshot("/foo.rsml", VfsSnapshot::file("TextButton {  }"))
            .unwrap();

        let mut vfs = Vfs::new(imfs.clone());

        let instance_snapshot = snapshot_rsml(
            &InstanceContext::default(),
            &mut vfs,
            Path::new("/foo.rsml"),
            "foo",
        )
        .unwrap()
        .unwrap();

        insta::assert_yaml_snapshot!(instance_snapshot);
    }
}