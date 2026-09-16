-- GC6E01 internal PokemonStats / poke_face identity <-> National Dex.
--
-- Kanto/Johto are identity-mapped. Hoenn is deliberately NOT National order:
-- the retail table shuffles many species (for example Ralts is internal 392,
-- Kyogre 404, Latias 407, Chimecho 411). These 135 mappings were source-derived
-- by matching each retail PokemonStats row against independently extracted Gen
-- III species fingerprints, with one unique match for every species.
local I={version=1,DEX_TO_INTERNAL={}}
for dex=1,251 do I.DEX_TO_INTERNAL[dex]=dex end
local H={
 [252]=277,[253]=278,[254]=279,[255]=280,[256]=281,[257]=282,[258]=283,[259]=284,[260]=285,[261]=286,
 [262]=287,[263]=288,[264]=289,[265]=290,[266]=291,[267]=292,[268]=293,[269]=294,[270]=295,[271]=296,
 [272]=297,[273]=298,[274]=299,[275]=300,[276]=304,[277]=305,[278]=309,[279]=310,[280]=392,[281]=393,
 [282]=394,[283]=311,[284]=312,[285]=306,[286]=307,[287]=364,[288]=365,[289]=366,[290]=301,[291]=302,
 [292]=303,[293]=370,[294]=371,[295]=372,[296]=335,[297]=336,[298]=350,[299]=320,[300]=315,[301]=316,
 [302]=322,[303]=355,[304]=382,[305]=383,[306]=384,[307]=356,[308]=357,[309]=337,[310]=338,[311]=353,
 [312]=354,[313]=386,[314]=387,[315]=363,[316]=367,[317]=368,[318]=330,[319]=331,[320]=313,[321]=314,
 [322]=339,[323]=340,[324]=321,[325]=351,[326]=352,[327]=308,[328]=332,[329]=333,[330]=334,[331]=344,
 [332]=345,[333]=358,[334]=359,[335]=380,[336]=379,[337]=348,[338]=349,[339]=323,[340]=324,[341]=326,
 [342]=327,[343]=318,[344]=319,[345]=388,[346]=389,[347]=390,[348]=391,[349]=328,[350]=329,[351]=385,
 [352]=317,[353]=377,[354]=378,[355]=361,[356]=362,[357]=369,[358]=411,[359]=376,[360]=360,[361]=346,
 [362]=347,[363]=341,[364]=342,[365]=343,[366]=373,[367]=374,[368]=375,[369]=381,[370]=325,[371]=395,
 [372]=396,[373]=397,[374]=398,[375]=399,[376]=400,[377]=401,[378]=402,[379]=403,[380]=407,[381]=408,
 [382]=404,[383]=405,[384]=406,[385]=409,[386]=410,
}
for dex,internal in pairs(H) do I.DEX_TO_INTERNAL[dex]=internal end
I.INTERNAL_TO_DEX={}
for dex,internal in pairs(I.DEX_TO_INTERNAL) do
  assert(I.INTERNAL_TO_DEX[internal]==nil,"duplicate Colosseum internal species id")
  I.INTERNAL_TO_DEX[internal]=dex
end
function I.internalForDex(dex)return I.DEX_TO_INTERNAL[tonumber(dex)]end
function I.dexForInternal(internal)return I.INTERNAL_TO_DEX[tonumber(internal)]end
return I
