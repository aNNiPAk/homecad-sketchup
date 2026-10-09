require_relative 'test_electrical_system'

class KitchenCompositionTest < ElectricalSystemTest
  def module_input(type, extra = {})
    { 'key'=>'m', 'type'=>type, 'width_mm'=>600 }.merge(extra)
  end

  def plan_for(type, extra = {})
    HomeCAD::Kitchen.plan(@model,{'wall'=>target(wall),'start_mm'=>0,'end_mm'=>600,
      'side'=>'positive_v','modules'=>[module_input(type,extra)]})
  end

  def apply_plan(plan)
    HomeCAD::Kitchen.apply(@model,'plan'=>plan)
  end

  def test_all_module_types_use_shared_definition_and_matching_parts
    HomeCAD::Kitchen::TYPES.each_key do |type|
      plan=plan_for(type)
      item=plan['params']['modules'].first
      config=HomeCAD::KitchenCabinetDefinition.for_module(@model,item)
      if %w[dishwasher fridge].include?(type)
        assert_nil config
        next
      end
      assert_equal 'construction',config['detail_level']
      assert_equal 1,item['composition_version']
      assert config['shelf_z_mm'].any? if %w[base_shelves wall_shelves tall_storage].include?(type)
      result=apply_plan(plan); run=entity(result['created'].first['homecad_id'])
      child=run.entities.find { |e| HomeCAD::Metadata.read(e)['module_key']=='m' }
      parts=HomeCAD::Furniture.part_schedule(config)
      records=HomeCAD::Cutlist.generate(@model,'target'=>target(result['created'].first['homecad_id']))['records']
      parts.each do |part|
        group=child.entities.find { |e| e.name==part['part_key'] }
        refute_nil group, "#{type}:#{part['part_key']}"
        size=case part['part_kind']
        when 'drawer_side' then [part['thickness_mm'],part['width_mm'],part['height_mm']]
        when 'shelf','drawer_base' then [part['width_mm'],part['height_mm'],part['thickness_mm']]
        else
          if part['part_key'].end_with?('_side')
            [part['thickness_mm'],part['width_mm'],part['height_mm']]
          elsif %w[top bottom].include?(part['part_key'])
            [part['width_mm'],part['height_mm'],part['thickness_mm']]
          else [part['width_mm'],part['thickness_mm'],part['height_mm']]
          end
        end
        min=group.bounds.corner(0); max=group.bounds.corner(7)
        actual=[max.x-min.x,max.y-min.y,max.z-min.z].map { |v| HomeCAD::Units.internal_to_mm(v) }
        size.zip(actual).each { |want,got| assert_in_delta want,got,0.01,"#{type}:#{part['part_key']}" }
        [min.x,min.y,min.z].map { |v| HomeCAD::Units.internal_to_mm(v) }.zip(part['origin_mm']).each { |got,want| assert_in_delta want,got,0.01 }
        row=records.find { |r| r['part_key']=="module:m/#{part['part_key']}" }
        assert_equal part['length_mm'],row['length_mm']
        assert_equal part['width_mm'],row['width_mm']
        assert_equal part['thickness_mm'],row['thickness_mm']
      end
      HomeCAD::Kitchen.delete(@model,'target'=>target(result['created'].first['homecad_id']))
    end
  end

  def test_drawers_schedules_uuid_update_invalid_fit_and_one_operation
    result=apply_plan(plan_for('base_drawers')); id=result['created'].first['homecad_id']
    child_id=result['created'].find { |r| r['module_key']=='m' || r.dig('metadata','module_key')=='m' }&.dig('homecad_id')
    child_id=HomeCAD::KitchenData.read(entity(id))['semantic_objects']['module:m']['homecad_id']
    rows=HomeCAD::Cutlist.generate(@model,'target'=>target(id))['records']
    assert_equal 10,rows.count { |r| r['part_key'].start_with?('module:m/drawer:') && r['record_kind']=='panel' }
    slides=rows.select { |r| r['part_kind']=='drawer_slide_pair' }
    assert_equal 2,slides.length; assert slides.all? { |r| r['sku'].nil? }
    @model.events.clear
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'end_mm'=>700,
      'modules'=>[module_input('base_drawers','width_mm'=>700)]})
    assert_equal [:start,:commit],@model.events.map(&:first)
    assert_equal child_id,HomeCAD::KitchenData.read(entity(id))['semantic_objects']['module:m']['homecad_id']
    before=HomeCAD::KitchenData.read(entity(id)); revision=HomeCAD::Metadata.read(entity(id))['revision']
    @model.events.clear
    error=assert_raises(HomeCAD::Runtime::BridgeError) do
      HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'modules'=>[module_input('base_drawers','drawer_layout'=>{'slide'=>{
        'family_id'=>HomeCAD::HardwareCatalog::FAMILY_ID,'sku'=>'PROJECT','nominal_length_mm'=>2000,'side_clearance_mm'=>10}})]})
    end
    assert_equal 'constraint_violation',error.category
    assert_empty @model.events
    assert_equal before,HomeCAD::KitchenData.read(entity(id))
    assert_equal revision,HomeCAD::Metadata.read(entity(id))['revision']
  end

  def test_project_defaults_and_zero_back_are_snapshotted
    HomeCAD::ProjectSettings.update(@model,'panel_thickness_mm'=>20,'back_thickness_mm'=>0,'material_id'=>'board')
    plan=plan_for('base_shelves')
    item=plan['params']['modules'].first
    assert_equal 20,item['panel_thickness_mm']; assert_equal 0,item['back_thickness_mm']
    config=HomeCAD::KitchenCabinetDefinition.for_module(@model,item)
    refute HomeCAD::Furniture.part_schedule(config).any? { |r| r['part_key']=='back' }
    assert_equal 560,HomeCAD::Furniture.part_schedule(config).find { |r| r['part_kind']=='shelf' }['length_mm']
    result=apply_plan(plan); id=result['created'].first['homecad_id']
    HomeCAD::ProjectSettings.update(@model,'panel_thickness_mm'=>22)
    @model.events.clear
    HomeCAD::Kitchen.update(@model,'target'=>target(id),'changes'=>{'name'=>'Kitchen run'})
    assert_empty @model.events
    assert_equal 20,HomeCAD::KitchenData.read(entity(id))['modules'].first['panel_thickness_mm']
  end
end
